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
# 默认目标：Image。若把 KernelSU 编成模块（CONFIG_KSU=m），
# 只编 Image 不会产出 kernelsu.ko，必须一起编 modules。
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
# 而 kernel/oplus_cpu/sched/ 并不在开源仓库里，于是 make gki_defconfig 直接失败。
# 这里扫描所有 Kconfig 的 source 语句，路径不存在的注释掉。
# 注意两点（都踩过）：
#   1. 用 find 而不是 grep -r --include（busybox grep 无 --include）
#   2. set -e 下循环体最后一条命令必须返回 0，否则整个脚本被杀，
#      所以判断一律写成显式 if，不要用 [ ] || [ ] && continue
echo "[+] 检查断裂的 Kconfig source 引用"
BROKEN=0
LIST=/tmp/_ksu_src_list.txt
: > "$LIST"
while IFS= read -r f; do
    grep -n '^[[:space:]]*source[[:space:]]*"' "$f" 2>/dev/null >> "$LIST.k" || true
    # 给每行加上文件名前缀
    if [ -s "$LIST.k" ]; then
        sed "s|^|$f	|" "$LIST.k" >> "$LIST"
        : > "$LIST.k"
    fi
done < <(find . -type f -name 'Kconfig*' -print 2>/dev/null)
rm -f "$LIST.k"

while IFS="$(printf '\t')" read -r kfile kline_rest; do
    if [ -z "$kfile" ]; then
        continue
    fi
    kline=${kline_rest%%:*}
    if [ -z "$kline" ]; then
        continue
    fi
    src=$(sed -n "${kline}p" "$kfile" 2>/dev/null \
          | sed -n 's/.*source[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -z "$src" ]; then
        continue
    fi
    if [ ! -e "$src" ]; then
        echo "  [!] $kfile:$kline 引用不存在的 $src，注释掉"
        sed -i "${kline}s|^|# [missing in vendor source] |" "$kfile"
        BROKEN=$((BROKEN+1))
    fi
done < "$LIST"
echo "[+] 断裂 Kconfig 引用处理完毕（共 $BROKEN 处）"

echo "[+] 使用 defconfig: $DEFPATH"
# kbuild 要求 defconfig 在 arch/$ARCH/configs 下才能用 make <name>，
# 用户自定义路径时把他的文件复制成标准名字再 make
DEFBASE="$(basename "$DEFPATH")"
if [ "$DEFPATH" != "arch/arm64/configs/$DEFBASE" ]; then
    cp "$DEFPATH" "arch/arm64/configs/$DEFBASE"
    echo "[+] 已复制到 arch/arm64/configs/$DEFBASE 供 kbuild 使用"
fi
timeout 600 make "$DEFBASE"
echo "[+] .config 已生成"

# ---------- 2. 追加 SukiSU Nova 配置 ----------
# 重要顺序（踩过两次坑，已用 kconfiglib 实测确认）：
#   1. 先 make olddefconfig 让 Kconfig 把所有符号按依赖关系填好
#   2. 再用 scripts/config 逐个写入我们关心的值
#   3. 写完直接编译，绝不再跑 olddefconfig
# 反例 A（先写再 olddefconfig）：olddefconfig 按依赖把不满足条件的项丢掉
# 反例 B（写后再 olddefconfig）：它会按 Kconfig 的 default 重置我们写的值，
#        实测 `--module KSU` 写成的 =m 会被立刻打回 =y，
#        CONFIG_KPM（default n）会被清成 is not set。
KSU_MODE=$([ "$KSU_AS_MODULE" = "true" ] && echo m || echo y)

# 分支差异检测：main 分支 KSU 是 tristate（可 =m），builtin 是 bool（只能 y）
if [ "$KSU_MODE" = "m" ] && [ -f "$KROOT/KernelSU/Kconfig" ]; then
    if sed -n '/^config KSU$/,/^\S/p' "$KROOT/KernelSU/Kconfig" | grep -q '^[[:space:]]*bool'; then
        echo "::warning::当前 Nova 分支的 CONFIG_KSU 是 bool，无法编成模块，将按内置 y 处理"
        KSU_MODE=y
    fi
fi

# CONFIG_KSU=m 时追加 modules 目标，否则 kernelsu.ko 不会产出
if [ "$KSU_MODE" = "m" ]; then
    case "$MAKE_GOALS" in
        *modules*) : ;;
        *) MAKE_GOALS="$MAKE_GOALS modules modules_prepare" ;;
    esac
    echo "[+] KSU 编为模块，MAKE_GOALS 追加 modules"
fi
echo "[+] 最终 MAKE_GOALS = $MAKE_GOALS"

echo "[+] 第 1 次 olddefconfig（建立依赖基线）"
# 注意 pipefail：`yes "" | make` 中 yes 会收到 SIGPIPE 而返回 141，
# 整条管道就算失败。所以先落到文件再看 make 的真实退出码。
if ! { set +o pipefail; yes "" | make olddefconfig > /tmp/_olddef1.log 2>&1; }; then
    echo "::error::make olddefconfig 失败"
    tail -20 /tmp/_olddef1.log
    exit 1
fi
tail -3 /tmp/_olddef1.log

# 配置写入：不再依赖 scripts/config，也不做任何 kconfig 解析。
# 原因：scripts/config 在 CI 上执行结果不可观测（日志里连回显都没有），
# 而 ENABLE_XXX=y 这种行本身对 kbuild 就是合法的，直接写 .config 即可。
# kbuild 在编译时会用 .config 里的值，不会因为「没经过 olddefconfig」而失效。
KCONF_APPLIED=/tmp/_ksu_applied.txt
: > "$KCONF_APPLIED"

# 写入单个配置项：先删同名旧行（含 is not set 形式），再追加
put_conf() {
    local sym="$1" val="$2"
    sed -i "/^CONFIG_${sym}=/d; /^# CONFIG_${sym} is not set/d" .config
    if [ "$val" = "n" ]; then
        # bool/tristate 的「关闭」在 .config 里的规范写法是注释形式，
        # 写成 CONFIG_X=n 虽然 kbuild 也认，但会触发 syncconfig 重写，
        # 保险起见用标准形式
        echo "# CONFIG_${sym} is not set" >> .config
        echo "# CONFIG_${sym} is not set" >> "$KCONF_APPLIED"
    else
        echo "CONFIG_${sym}=${val}" >> .config
        echo "CONFIG_${sym}=${val}" >> "$KCONF_APPLIED"
    fi
}

# ---------- 2.1 CONFIG_HZ ----------
# 必须显式设置。内核生成 include/generated/timeconst.h 用：
#     filechk_gentimeconst = echo $(CONFIG_HZ) | bc -q kernel/time/timeconst.bc
# CONFIG_HZ 为空时 bc 拿到空输入，filechk 因输出不匹配反复重试，
# 表现为 prepare 阶段挂死（run #12/#14 各挂满 30 分钟被 timeout 杀掉）。
if grep -q '^CONFIG_HZ=' .config; then
    echo "[=] .config 已有 CONFIG_HZ，保持原值"
else
    echo "[+] 补充 CONFIG_HZ=250（原 defconfig 未定义，会导致 timeconst 生成挂起）"
    put_conf HZ 250
fi

# ---------- 2.2 KernelSU ----------
put_conf KPROBES y
put_conf EXT4_FS y
put_conf KSU "$KSU_MODE"

if [ "$ENABLE_KPM" = "true" ]; then
    put_conf KPM y
    if [ "$KSU_MODE" = "y" ]; then
        put_conf KALLSYMS y
        put_conf KALLSYMS_ALL y
    fi
fi

# ---------- 2.3 LTO / CFI ----------
# FULL LTO 在 4 核 16G runner 上极易 OOM，默认 thin
LTO_MODE="${LTO_MODE:-thin}"
echo "[+] LTO 模式: $LTO_MODE"
case "$LTO_MODE" in
    full)
        put_conf LTO_CLANG_FULL y
        put_conf LTO_CLANG_THIN n
        ;;
    thin)
        put_conf LTO_CLANG_FULL n
        put_conf LTO_CLANG_THIN y
        ;;
    none)
        put_conf LTO_CLANG_FULL n
        put_conf LTO_CLANG_THIN n
        put_conf CFI_CLANG n
        echo "[!] 已关闭 LTO，同时关闭 CFI_CLANG（CFI 依赖 LTO）"
        ;;
esac

# ---------- 2.4 BTF ----------
BTF_MODE="${BTF_MODE:-off}"
if [ "$BTF_MODE" = "on" ]; then
    echo "[+] 保留 DEBUG_INFO_BTF"
    command -v pahole >/dev/null 2>&1 && pahole --version || echo "::warning::未找到 pahole"
else
    put_conf DEBUG_INFO_BTF n
    put_conf DEBUG_INFO_BTF_MODULES n
    echo "[+] 已关闭 DEBUG_INFO_BTF（避免 pahole 版本不匹配中断编译）"
fi

# ---------- 2.5 模块签名 ----------
put_conf MODULE_SIG n
echo "[+] 已关闭 MODULE_SIG（自编内核无签名链）"

# ---------- 2.6 用户自定义 ----------
if [ -n "${EXTRA_DEFCONFIG:-}" ]; then
    echo "[+] 追加 extra_defconfig:"
    echo -e "$EXTRA_DEFCONFIG" | while IFS= read -r line; do
        if [ -z "$line" ]; then continue; fi
        case "$line" in \#*) continue ;; esac
        echo "    $line"
        sym=$(printf '%s' "$line" | sed -n 's/^CONFIG_\([A-Za-z0-9_]*\)=.*/\1/p')
        val=$(printf '%s' "$line" | sed -n 's/^CONFIG_[A-Za-z0-9_]*=\(.*\)/\1/p')
        if [ -z "$sym" ]; then continue; fi
        case "$val" in
            y) "$KCONF" --enable  "$sym" ;;
            m) "$KCONF" --module  "$sym" ;;
            n) "$KCONF" --disable "$sym" ;;
            *) "$KCONF" --set-val "$sym" "$val" ;;
        esac
    done
fi

# ---------- 2.7 收敛 ----------
# 千万不要在这里再跑 olddefconfig！
# 已实测：olddefconfig 会按 Kconfig 的 default 重置我们用 scripts/config
# 强行写入的值。例如 Nova 的 `config KSU ... default y`，
# --module KSU 写成 =m 后，再 olddefconfig 立刻被打回 =y；
# 同理 CONFIG_KPM（default n）会被清成 is not set。
# 正确顺序是：olddefconfig 建基线（上面第 1 次）-> scripts/config 写值 -> 直接编译。
echo "[+] 配置已写入，跳过第二次 olddefconfig（它会重置上面写入的值）"

# 只做一次轻量校验：所有 .config 里的值语法合法，且关键项还在
if grep -qE '^CONFIG_KSU=.$' .config; then
    :
else
    echo "::warning::CONFIG_KSU 行格式异常"
fi

echo "==================== 配置写入结果 ===================="
echo "--- 本次 put_conf 写入的记录 ---"
cat "$KCONF_APPLIED" 2>/dev/null || echo "  <空>"
echo "--- .config 中实际存在的相关项（直接 grep 文件，不经管道）---"
grep -E '^CONFIG_(MODULES|KSU|KPROBES|EXT4_FS|KPM|HZ|KALLSYMS|KALLSYMS_ALL|LTO_CLANG_THIN|LTO_CLANG_FULL|CFI_CLANG|DEBUG_INFO_BTF|MODULE_SIG)=' .config > /tmp/_ksu_final.txt 2>/dev/null || true
if [ -s /tmp/_ksu_final.txt ]; then
    cat /tmp/_ksu_final.txt
else
    echo "  <一个都没有，说明 .config 异常>"
fi
echo "--- 上述项的 is-not-set 形式 ---"
grep -E '^# CONFIG_(KSU|KPM|LTO_CLANG_FULL|DEBUG_INFO_BTF|MODULE_SIG) is not set' .config 2>/dev/null || echo "  <无>"
echo "--- .config 总行数: $(wc -l < .config) ---"

# KSU 必须真的进了 .config，否则编出来是普通内核
if ! grep -qE '^CONFIG_KSU=[ym]' .config; then
    echo "::error::CONFIG_KSU 没有生效，编译出来不会是 KernelSU 内核"
    echo "        可能原因：库目录没有正确接入（drivers/kernelsu）"
    echo "        检查 drivers/Kconfig 是否 source 了 kernelsu"
    grep -n 'kernelsu' drivers/Kconfig drivers/Makefile 2>/dev/null || echo "        未找到 kernelsu 引用！"
    exit 1
fi

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

# 按内存自适应并发：单 job 峰值约 1.5~2G（LTO 更高）
MEM_JOBS=$(( MEM_MB / 2000 ))
if [ "$MEM_JOBS" -lt 1 ]; then MEM_JOBS=1; fi
if [ "$MEM_JOBS" -gt "$JOBS" ]; then MEM_JOBS=$JOBS; fi
echo "[+] 并发: $MEM_JOBS (nproc=$JOBS, mem=${MEM_MB}MB)"

echo "==================== 编译阶段 1/2: prepare ===================="
# 先单独跑 prepare。这一步会暴露 Kconfig/工具链层面的问题，
# 几秒内就能结束，不会像整编那样一跑一小时什么都看不见。
set +e
timeout 1800 make -j"${MEM_JOBS:-4}" prepare 2>&1 | tee /tmp/kernel-prepare.log | tail -20
RC=${PIPESTATUS[0]}
set -e
if [ "$RC" -ne 0 ]; then
    echo "::error::prepare 阶段失败（退出码 $RC）"
    tail -40 /tmp/kernel-prepare.log
    exit "$RC"
fi
echo "[+] prepare 通过"

echo "==================== 编译阶段 2/2: $MAKE_GOALS ===================="
# 后台心跳：每 60 秒打印已运行时长和日志行数，
# 这样即使 make 卡住，日志里也能看出「停在哪个时间点」。
# 之前跑了 68 分钟无任何输出，就是因为没有这个。
START_TS=$(date +%s)
# 心跳用「有限次数 + 短 sleep」而不是 while true + sleep 60：
# kill 子 shell 杀不掉它内部的 sleep，会让 CI 步骤在脚本结束后仍挂住。
# 这里改成最多 130 次、每次 55 秒（约 2 小时），并用子 shell 的 PGID 兜底清理。
(
  i=0
  while [ "$i" -lt 130 ]; do
    sleep 55
    i=$((i+1))
    if [ -f /tmp/kernel-build.log ]; then
      printf '[heartbeat] 已编译 %d 分钟，日志 %d 行，最后一条: %s\n' \
        "$(( $(date +%s) - START_TS ))" \
        "$(wc -l < /tmp/kernel-build.log 2>/dev/null || echo 0)" \
        "$(tail -1 /tmp/kernel-build.log 2>/dev/null | cut -c1-100 || true)"
    fi
  done
) &
HB_PID=$!

set +e
# timeout 兜底：120 分钟还没完说明卡死了，直接杀并打印现场
# shellcheck disable=SC2086
timeout 7200 make -j"$MEM_JOBS" $MAKE_GOALS 2>&1 | tee /tmp/kernel-build.log
BUILD_RC=${PIPESTATUS[0]}
set -e
if [ -n "${HB_PID:-}" ]; then
    kill -TERM "$HB_PID" 2>/dev/null || true
    # 兜底：连带它的子进程（sleep）一起收掉，否则 CI 步骤结束后仍会挂住
    pkill -TERM -P "$HB_PID" 2>/dev/null || true
    wait "$HB_PID" 2>/dev/null || true
fi

if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::内核编译失败（退出码 $BUILD_RC）"
    if [ "$BUILD_RC" -eq 124 ]; then
        echo "::error::编译超过 120 分钟被 timeout 终止，最后进度："
    fi
    echo "----- 日志行数: $(wc -l < /tmp/kernel-build.log 2>/dev/null || echo 0) -----"
    echo "----- 错误摘要 -----"
    grep -nE 'error:|Error [0-9]|fatal error|undefined reference|Killed|out of memory|cannot find' \
        /tmp/kernel-build.log | tail -25 || true
    echo "----- 最后 60 行 -----"
    tail -60 /tmp/kernel-build.log
    exit "$BUILD_RC"
fi
echo "[+] 编译完成，用时 $(( $(date +%s) - START_TS )) 秒"

# 尝试生成压缩镜像（可选，不阻塞）
echo "[+] 尝试生成 Image.gz / Image.lz4 ..."
timeout 600 make -j"$(nproc)" Image.gz >/dev/null 2>&1 || true
if command -v lz4 >/dev/null 2>&1; then timeout 600 make -j"$(nproc)" Image.lz4 >/dev/null 2>&1 || true; fi

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

# ---------- 4.1 收集 KernelSU 模块 ----------
if [ "$KSU_MODE" = "m" ]; then
    echo "[+] 查找 kernelsu.ko"
    KSU_KO=$(find "$KROOT" -name 'kernelsu.ko' -type f 2>/dev/null | head -1)
    if [ -n "$KSU_KO" ]; then
        cp -v "$KSU_KO" "$GITHUB_WORKSPACE/out/kernelsu.ko"
        echo "[+] kernelsu.ko 已收集（供 LKM 模式 insmod 或管理器集成）"
    else
        echo "::error::CONFIG_KSU=m 但没有产出 kernelsu.ko"
        echo "        可能 modules 目标没编到，检查 MAKE_GOALS"
        exit 1
    fi
fi

# 内核版本标识
KV=$(strings "$IMG_DIR/Image" | grep -m1 "Linux version" || true)
[ -n "$KV" ] && echo "$KV" | tee "$GITHUB_WORKSPACE/out/kernel-version.txt"

# ---------- 5. AnyKernel3 刷机包（可选） ----------
if [ "$PACK_ANYKERNEL" = "true" ]; then
    echo "[+] 打包 AnyKernel3 ..."
    AK_DIR="$GITHUB_WORKSPACE/AnyKernel3"
    rm -rf "$AK_DIR"
    if git clone --depth 1 "$ANYKERNEL_REPO" "$AK_DIR" 2>/dev/null; then
        rm -rf "$AK_DIR/.git"
        cp "$IMG_DIR/Image" "$AK_DIR/Image"
        for ext in lz4 gz xz; do
            if [ -f "$IMG_DIR/Image.$ext" ]; then
                cp "$IMG_DIR/Image.$ext" "$AK_DIR/Image.$ext"
            fi
        done
        KVER=$(cat "$GITHUB_WORKSPACE/out/kernel-version.txt" 2>/dev/null \
               | sed -E 's/Linux version ([^ ]+) .*/\1/' || true)
        ZIP_NAME="AnyKernel3-${KVER:-kernel}.zip"
        if (cd "$AK_DIR" && zip -q -r9 "$GITHUB_WORKSPACE/out/$ZIP_NAME" .); then
            echo "[+] AnyKernel3 打包完成: $ZIP_NAME"
        else
            echo "::warning::zip 打包失败，保留 Image"
        fi
    else
        echo "::warning::AnyKernel3 克隆失败，跳过刷机包（仍保留 Image）"
    fi
fi

echo "==================== 构建完成 ===================="
ls -la "$GITHUB_WORKSPACE/out/"