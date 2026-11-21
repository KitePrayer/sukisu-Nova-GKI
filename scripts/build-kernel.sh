#!/bin/bash
# =====================================================================
# 内核编译 + SukiSU Nova 集成 + 产物打包
# ---------------------------------------------------------------------
# 由 build-kernel.yml 调用。流程：
#   1. 用指定 defconfig 生成 .config（arm64 专用路径，含 32 位模拟）
#   2. 追加 SukiSU Nova 及用户自定义配置
#   3. 用 AOSP clang（+可选 GCC）交叉编译
#   4. 收集 Image* 产物
#   5. （可选）塞进 AnyKernel3 模板打成可刷机 zip
#
# 环境变量：
#   KROOT         内核源码根目录
#   DEFCONFIG     defconfig 名（如 gki_defconfig）
#   CLANG_DIR     AOSP clang 目录（含 bin/clang）
#   USE_GCC       true 时启用 GCC CROSS_COMPILE
#   GCC_DIR       GCC 交叉编译器目录
#   KSU_AS_MODULE true=CONFIG_KSU=m，否则=y
#   ENABLE_KPM    true 时 CONFIG_KPM=y
#   PACK_ANYKERNEL true 时打包 AnyKernel3
#   ANYKERNEL_REPO AnyKernel3 模板 git 地址
# =====================================================================
set -euo pipefail

KROOT="${KROOT:?KROOT 未设置}"
DEFCONFIG="${DEFCONFIG:-gki_defconfig}"
CLANG_DIR="${CLANG_DIR:-}"
USE_GCC="${USE_GCC:-false}"
GCC_DIR="${GCC_DIR:-}"
KSU_AS_MODULE="${KSU_AS_MODULE:-false}"
ENABLE_KPM="${ENABLE_KPM:-false}"
PACK_ANYKERNEL="${PACK_ANYKERNEL:-true}"
ANYKERNEL_REPO="${ANYKERNEL_REPO:-https://github.com/osm0sis/AnyKernel3.git}"

cd "$KROOT"
echo "==================== 内核构建环境 ===================="
echo "KROOT      : $KROOT"
echo "DEFCONFIG  : $DEFCONFIG"
uname -a
nproc

# ---------- 0. 工具链路径 ----------
export ARCH=arm64
# CLANG_BIN_DIR 是真正包含 clang / ld.lld / llvm-ar 的目录；
# 旧写法假定它是 $CLANG_DIR/bin，但解压包布局不一定是那样。
CLANG_BIN_DIR="${CLANG_BIN_DIR:-}"
if [ -z "$CLANG_BIN_DIR" ] && [ -n "${CLANG_DIR:-}" ]; then
    CLANG_BIN_DIR="$CLANG_DIR/bin"
fi
if [ -n "$CLANG_BIN_DIR" ] && [ -x "$CLANG_BIN_DIR/clang" ]; then
    export PATH="$CLANG_BIN_DIR:$PATH"
    echo "[+] clang bin 目录: $CLANG_BIN_DIR"
else
    echo "::warning::CLANG_BIN_DIR 未设置或其中没有 clang: '$CLANG_BIN_DIR'"
fi

# 编译器选择：
#   有 clang  -> clang 编译（GKI 内核的唯一可行路径，LTO/CFI 都依赖 clang）
#   无 clang  -> 回退 GCC（仅当 USE_GCC=true 且提供 GCC_DIR）
# LLVM=1 让 kbuild 用 clang 全套工具（llvm-ar/llvm-nm/ld.lld）
# 注意：clang 往往是符号链接，必须用 -x 而不是 -f 判断
if [ -n "$CLANG_BIN_DIR" ] && [ -x "$CLANG_BIN_DIR/clang" ]; then
    export CC=clang
    export LLVM=1
    echo "[+] 编译器: $("$CLANG_BIN_DIR/clang" --version | head -1)"
else
    export LLVM=0
    if [ "$USE_GCC" = "true" ] && [ -n "$GCC_DIR" ] && [ -x "$GCC_DIR/bin/aarch64-linux-gnu-gcc" ]; then
        export CC="$GCC_DIR/bin/aarch64-linux-gnu-gcc"
        echo "[+] 编译器: GCC ($CC)"
    else
        echo "::error::没有可用编译器（需要 CLANG_BIN_DIR 里有 clang，或 USE_GCC + GCC_DIR）"
        exit 1
    fi
fi

# ---------- 0.5 GKI 编译预检 ----------
# 这个内核的 gki_defconfig 里同时开了：
#   CONFIG_LTO_CLANG_FULL=y  FULL LTO 在 GitHub runner(7~16G 内存) 上基本 OOM
#   CONFIG_CFI_CLANG=y       紧跟 LTO，关 LTO 必须一起关，否则链接期报错
#   CONFIG_DEBUG_INFO_BTF=y  要 pahole 与 clang 版本配套，失败会中断编译
# 所以在这里显式处理，而不是等 make 跑到一半 OOM 再猜。
echo "==================== GKI 编译预检 ===================="
MAKE_GOALS="${MAKE_GOALS:-Image}"
echo "MAKE_GOALS = $MAKE_GOALS"

# 内存
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
echo "可用内存: ${MEM_MB} MB"
JOBS=$(nproc)

# ---------- 1. 生成 .config ----------
# defconfig 位置优先级：用户指定的 defconfig_path > 常见默认目录
DEFPATH=""
if [ -n "${DEFCONFIG_PATH:-}" ]; then
    # 用户指定目录（支持相对内核根或绝对路径）
    if [ -f "$KROOT/${DEFCONFIG_PATH#$KROOT/}/$DEFCONFIG" ]; then
        DEFPATH="$KROOT/${DEFCONFIG_PATH#$KROOT/}/$DEFCONFIG"
    elif [ -f "$DEFCONFIG_PATH/$DEFCONFIG" ]; then
        DEFPATH="$DEFCONFIG_PATH/$DEFCONFIG"
    else
        echo "::error::defconfig_path=$DEFCONFIG_PATH 下未找到 $DEFCONFIG"
        exit 1
    fi
else
    for p in "arch/arm64/configs/$DEFCONFIG" \
             "arch/arm64/configs/gki/$DEFCONFIG" \
             "arch/arm64/configs/vendor/$DEFCONFIG"; do
        if [ -f "$p" ]; then DEFPATH="$p"; break; fi
    done
fi
if [ -z "$DEFPATH" ]; then
    echo "::error::defconfig 不存在: $DEFCONFIG（找过 arch/arm64/configs 及子目录）"
    exit 1
fi
# kbuild 的 %config 规则要求文件名以 defconfig 结尾，否则 make 无法识别
case "$DEFCONFIG" in
    *defconfig) : ;;
    *) echo "::error::defconfig 文件名必须以 'defconfig' 结尾（当前: $DEFCONFIG）"
       echo "         kbuild 用 make %config 规则匹配，如 foo_defconfig"
       exit 1 ;;
esac
# ---------- 1.5 修补仓库自带的断裂 Kconfig 引用 ----------
# 厂商开源仓库常把私有代码目录放成空壳（或干脆不提交），但 Kconfig 里
# 仍有无条件 source。例如 realme GT5_GT5240W 的 init/Kconfig:874 引用了
#   source "kernel/oplus_cpu/sched/Kconfig"
# 而 kernel/oplus_cpu/sched/ 并不在开源仓库里，于是 make gki_defconfig 直接失败：
#   init/Kconfig:874: can't open file "kernel/oplus_cpu/sched/Kconfig"
# 这里扫描所有 Kconfig 里的 source 语句，路径不存在的就注释掉。
# 注意：用 find 而不是 grep -r --include（busybox grep 不支持 --include）
echo "[+] 检查断裂的 Kconfig source 引用"
BROKEN=0
: > /tmp/_ksu_src_list.txt
find . -type f -name 'Kconfig*' -print 2>/dev/null | while IFS= read -r f; do
    grep -n '^[[:space:]]*source[[:space:]]*"' "$f" 2>/dev/null | \
        while IFS= read -r kv; do
            ln=${kv%%:*}
            printf '%s\t%s\n' "$f" "$ln"
        done
done > /tmp/_ksu_src_list.txt

while IFS="$(printf '\t')" read -r kfile kline; do
    [ -z "$kfile" ] || [ -z "$kline" ] && continue
    src=$(sed -n "${kline}p" "$kfile" 2>/dev/null \
          | sed -n 's/.*source[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$src" ] && [ ! -e "$src" ]; then
        echo "  [!] $kfile:$kline 引用不存在的 $src，注释掉"
        sed -i "${kline}s|^|# [missing in vendor source] |" "$kfile"
        BROKEN=$((BROKEN+1))
    fi
done < /tmp/_ksu_src_list.txt
echo "[+] 断裂 Kconfig 引用处理完毕（共 $BROKEN 处）"

echo "[+] 使用 defconfig: $DEFPATH"
# kbuild 要求 defconfig 在 arch/$ARCH/configs 下才能用 make <name>，
# 用户自定义路径时把他的文件复制成标准名字再 make
DEFBASE="$(basename "$DEFPATH")"
if [ "$DEFPATH" != "arch/arm64/configs/$DEFBASE" ]; then
    cp "$DEFPATH" "arch/arm64/configs/$DEFBASE"
    echo "[+] 已复制到 arch/arm64/configs/$DEFBASE 供 kbuild 使用"
fi
make "$DEFBASE"
echo "[+] .config 已生成"

# ---------- 2. 追加 SukiSU Nova 配置 ----------
# main 分支 = kprobe 方案（推荐内置，也支持模块）
# builtin 分支 = 手动 hook 方案（必须内置 CONFIG_KSU=y）
KSU_MODE=$([ "$KSU_AS_MODULE" = "true" ] && echo m || echo y)

# 分支差异检测：main 分支的 KSU 是 tristate（可 =m），builtin 分支是 bool（只能 y）
if [ "$KSU_MODE" = "m" ] && [ -f "$KROOT/KernelSU/Kconfig" ]; then
    if sed -n '/^config KSU$/,/^\S/p' "$KROOT/KernelSU/Kconfig" | grep -q '^\s*bool'; then
        echo "::warning::当前 Nova 分支的 CONFIG_KSU 是 bool，无法编成模块；"
        echo "           ksu_as_module=true 会被 kbuild 规整为内置 y。"
        echo "           若确实要 LKM 模式，请用 nova_branch=main。"
    fi
fi

# 写配置项：先删掉 .config 里同名旧行，避免重复项（kbuild 虽然后者生效，
# 但重复行会让 `grep` 检查产生误导，也不符合 .config 规范）
set_conf() {
    local key="$1" val="$2"
    sed -i "/^${key}=/d; /^# ${key} is not set/d" .config
    echo "${key}=${val}" >> .config
}

set_conf CONFIG_KSU "$KSU_MODE"
set_conf CONFIG_KPROBES y
set_conf CONFIG_EXT4_FS y
if [ "$ENABLE_KPM" = "true" ]; then
    set_conf CONFIG_KPM y
    if [ "$KSU_MODE" = "y" ]; then
        set_conf CONFIG_KALLSYMS y
        set_conf CONFIG_KALLSYMS_ALL y
    fi
fi

# ---------- 2.5 GKI 三大编译门槛 ----------
# LTO：FULL LTO 是整内核单模块优化，内存需求是 THIN 的数倍。
#       runner 上 7G 内存必 OOM，所以默认降到 thin；THIN 也吃紧时再关掉。
# CFI：依赖 LTO，关 LTO 必须同时关 CFI，否则链接期 "CFI requires LTO"。
LTO_MODE="${LTO_MODE:-thin}"
echo "[+] LTO 模式: $LTO_MODE"
case "$LTO_MODE" in
    full)
        set_conf CONFIG_LTO_CLANG_FULL y
        set_conf CONFIG_LTO_CLANG_THIN n
        ;;
    thin)
        set_conf CONFIG_LTO_CLANG_FULL n
        set_conf CONFIG_LTO_CLANG_THIN y
        ;;
    none)
        set_conf CONFIG_LTO_CLANG_FULL n
        set_conf CONFIG_LTO_CLANG_THIN n
        set_conf CONFIG_LTO_NONE y
        # 关 LTO 就必须关 CFI，否则链接期直接报错
        set_conf CONFIG_CFI_CLANG n
        echo "[!] 已关闭 LTO，同时关闭 CONFIG_CFI_CLANG（CFI 依赖 LTO）"
        ;;
esac

# BTF：CONFIG_DEBUG_INFO_BTF 需要 pahole 与当前 clang 产物兼容。
#      GitHub runner 的 pahole 版本经常与内核要求不匹配，导致 vmlinux 生成失败。
#      默认关闭：这不影响内核启动，只影响 BTF 调试信息与 BPF CO-RE。
BTF_MODE="${BTF_MODE:-off}"
if [ "$BTF_MODE" = "on" ]; then
    echo "[+] 保留 CONFIG_DEBUG_INFO_BTF=y"
    command -v pahole >/dev/null 2>&1 && pahole --version || echo "::warning::未找到 pahole"
else
    set_conf CONFIG_DEBUG_INFO_BTF n
    set_conf CONFIG_DEBUG_INFO_BTF_MODULES n 2>/dev/null || true
    echo "[+] 已关闭 CONFIG_DEBUG_INFO_BTF（避免 pahole 版本不匹配中断编译）"
fi

# GKI ABI 强制检查：会在 KSU 加了符号后直接失败，编译阶段关掉。
# 注意这只影响编译期校验，不影响产出的 KMI 本身。
set_conf CONFIG_MODULE_SIG n 2>/dev/null || true
echo "[+] 已关闭 CONFIG_MODULE_SIG（自编内核无签名链）"

# 用户自定义 extra 配置（支持真换行或字面 \n）
if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
    echo "[+] 追加 extra_defconfig:"
    : > .config.new
    echo -e "$EXTRA_DEFCONFIG" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        printf '%s\n' "$line" >> .config.new
    done
    if [ -s .config.new ]; then
        cat .config.new >> .config
        sed 's/^/    /' .config.new
    fi
    rm -f .config.new
fi

# 让新增的 CONFIG_ 生效（_MODULE 相关会由 later olddefconfig 解析）
make olddefconfig >/dev/null 2>&1 || make oldconfig >/dev/null 2>&1 || true

echo "==================== 最终内核配置（KSU 相关） ===================="
grep -E "CONFIG_KSU|CONFIG_KPROBES|CONFIG_KPM" .config || true

# ---------- 3. 编译 ----------
CROSS_ARGS=()
if [ "$USE_GCC" = "true" ] && [ -n "$GCC_DIR" ]; then
    # 用 clang 时也经常需要 CROSS_COMPILE（给 ld 等 binutils，老内核）
    GCBIN="$GCC_DIR/bin"
    # 兼容两种命名（LineageOS 编译器是 aarch64-linux-gnu-，也有 aarch64-linux-android-）
    for gcc_pre in aarch64-linux-gnu- aarch64-linux-android-; do
        if [ -x "$GCBIN/${gcc_pre}gcc" ]; then
            export CROSS_COMPILE="$GCBIN/$gcc_pre"
            # 32 位兼容（老内核需要）
            if [ -x "$GCBIN/${gcc_pre//aarch64/arm}32-gcc" ] || [ -x "$GCBIN/arm-linux-gnueabi-gcc" ]; then
                export CROSS_COMPILE_COMPAT="${gcc_pre//aarch64/arm}32-"
            fi
            echo "[+] CROSS_COMPILE: $CROSS_COMPILE"
            break
        fi
    done
    if [ -z "${CROSS_COMPILE:-}" ]; then
        echo "::warning::未在 $GCC_DIR/bin 找到 aarch64 交叉 gcc，跳过 CROSS_COMPILE"
    fi
fi

echo "==================== 开始编译 ($MAKE_GOALS) ===================="
# 按内存自适应并发：内核编译单 job 峰值约 1.5~2G（LTO 更高）。
# 直接 -j$(nproc) 在 16 核/16G runner 上仍有 OOM 风险，按内存压一下。
MEM_JOBS=$(( MEM_MB / 2000 ))
[ "$MEM_JOBS" -lt 1 ] && MEM_JOBS=1
[ "$MEM_JOBS" -gt "$JOBS" ] && MEM_JOBS=$JOBS
echo "[+] 并发: $MEM_JOBS (nproc=$JOBS, mem=${MEM_MB}MB)"

# 注意：这里临时关掉 pipefail/set -e，否则 make 失败会立即退出，
# 导致下面的错误日志打印不出来（用户只能看到空失败）
set +e
# shellcheck disable=SC2086
make -j"$MEM_JOBS" $MAKE_GOALS 2>&1 | tee /tmp/kernel-build.log
BUILD_RC=${PIPESTATUS[0]}
set -e
if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::内核编译失败（退出码 $BUILD_RC）"
    echo "----- 错误摘要 -----"
    grep -nE 'error:|Error [0-9]|fatal error|undefined reference|Killed|out of memory|cannot find' \
        /tmp/kernel-build.log | tail -25 || true
    echo "----- 最后 60 行 -----"
    tail -60 /tmp/kernel-build.log
    exit "$BUILD_RC"
fi

# 尝试生成压缩镜像（可选，不阻塞）
echo "[+] 尝试生成 Image.gz / Image.lz4 ..."
make -j$(nproc) Image.gz >/dev/null 2>&1 || true
command -v lz4 >/dev/null 2>&1 && make -j$(nproc) Image.lz4 >/dev/null 2>&1 || true

# ---------- 4. 定位与收集产物 ----------
IMG_DIR=""
for cand in "arch/arm64/boot" "out/arch/arm64/boot"; do
    if [ -f "$KROOT/$cand/Image" ]; then IMG_DIR="$KROOT/$cand"; break; fi
done
if [ -z "$IMG_DIR" ]; then
    echo "::error::未找到编译产物 Image"
    find "$KROOT" -maxdepth 5 -name "Image*" 2>/dev/null | head
    exit 1
fi
echo "[+] 镜像目录: $IMG_DIR"

mkdir -p "$GITHUB_WORKSPACE/out"
cp -v "$IMG_DIR"/Image* "$GITHUB_WORKSPACE/out/" || true

# 内核版本标识
KV=$(strings "$IMG_DIR/Image" | grep -m1 "Linux version" || true)
[ -n "$KV" ] && echo "$KV" | tee "$GITHUB_WORKSPACE/out/kernel-version.txt"

# ---------- 5. AnyKernel3 刷机包（可选） ----------
if [ "$PACK_ANYKERNEL" = "true" ]; then
    echo "[+] 打包 AnyKernel3 ..."
    AK_DIR="$GITHUB_WORKSPACE/AnyKernel3"
    rm -rf "$AK_DIR"
    if ! git clone --depth 1 "$ANYKERNEL_REPO" "$AK_DIR" 2>/dev/null; then
        echo "::warning::AnyKernel3 克隆失败，跳过刷机包（仍保留 Image）"
        exit 0
    fi
    rm -rf "$AK_DIR/.git"
    # Image* 一律放根目录，AnyKernel3 的 anykernel.sh 会按需取用
    # （gki-2.0 分支模板已适配 Image.lz4 / Image.gz）
    cp "$IMG_DIR/Image" "$AK_DIR/Image"
    [ -f "$IMG_DIR/Image.lz4" ] && cp "$IMG_DIR/Image.lz4" "$AK_DIR/Image.lz4"
    [ -f "$IMG_DIR/Image.gz" ] && cp "$IMG_DIR/Image.gz" "$AK_DIR/Image.gz"
    [ -f "$IMG_DIR/Image.xz" ] && cp "$IMG_DIR/Image.xz" "$AK_DIR/Image.xz"
    # 生成刷机包
    ZIP_NAME="AnyKernel3-$(cat "$GITHUB_WORKSPACE/out/kernel-version.txt" 2>/dev/null | sed -E 's/Linux version ([^ ]+) .*/\1/' || echo kernel).zip"
    (cd "$AK_DIR" && zip -q -r9 "$GITHUB_WORKSPACE/out/$ZIP_NAME" .)
    echo "[+] AnyKernel3 打包完成: $ZIP_NAME"
fi

echo "==================== 构建完成 ===================="
ls -la "$GITHUB_WORKSPACE/out/"