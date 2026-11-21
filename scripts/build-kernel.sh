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
CLANG_PATH=""
if [ -n "$CLANG_DIR" ]; then
    CLANG_PATH="$CLANG_DIR/bin"
    export PATH="$CLANG_PATH:$PATH"
fi

# 编译器选择：
#   有 clang  -> clang 编译（主流，兼容 GCC/LLVM 两套）
#   无 clang  -> 回退 GCC（仅当 USE_GCC=true 且提供 GCC_DIR）
# LLVM=1 让 kbuild 用 clang 全套工具（llvm-ar/llvm-nm…），AOSP clang 自带
if [ -n "$CLANG_PATH" ] && [ -x "$CLANG_PATH/clang" ]; then
    export CC=clang
    export LLVM=1
    echo "[+] 编译器: AOSP clang ($CLANG_PATH)"
else
    export LLVM=0
    if [ "$USE_GCC" = "true" ] && [ -n "$GCC_DIR" ] && [ -x "$GCC_DIR/bin/aarch64-linux-gnu-gcc" ]; then
        export CC="$GCC_DIR/bin/aarch64-linux-gnu-gcc"
        echo "[+] 编译器: GCC ($CC)"
    else
        echo "::error::没有可用编译器（需要 CLANG_DIR 或 USE_GCC + GCC_DIR）"
        exit 1
    fi
fi

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

echo "==================== 开始编译 (Image) ===================="
# 注意：这里临时关掉 pipefail/set -e，否则 make 失败会立即退出，
# 导致下面的错误日志打印不出来（用户只能看到空失败）
set +e
make -j"$(nproc)" Image 2>&1 | tee /tmp/kernel-build.log
BUILD_RC=${PIPESTATUS[0]}
set -e
if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::内核编译失败（退出码 $BUILD_RC），最后 60 行日志："
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