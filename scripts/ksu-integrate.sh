#!/bin/bash
# =====================================================================
# 把 SukiSU Nova 集成到内核源码树（in-tree 模式）
# ---------------------------------------------------------------------
# 参考 Nova 官方 setup.sh 的等价操作，但把克隆源换成 GitHub：
#   官方:  git clone https://git.zako.shirkneko.top:20004/shirkneko/SukiSU KernelSU
#   本脚本: clone GitHub 上的 SukiSU-Nova/SukiSU-Nova（workflow 已克隆好）
#
# 操作（与官方 setup.sh 完全等价）：
#   1. 在 drivers/ 下建软链 kernelsu -> <Nova>/kernel
#   2. drivers/Makefile 追加 obj-$(CONFIG_KSU) += kernelsu/
#   3. drivers/Kconfig  追加 source "drivers/kernelsu/Kconfig"
#
# 环境变量：
#   KERNEL_DIR  内核源码根目录（含 drivers/）
#   NOVA_DIR    Nova 仓库的 kernel/ 目录
# =====================================================================
set -eu

GKI_ROOT="${KERNEL_DIR:?KERNEL_DIR 未设置}"
NOVA_KERNEL_DIR="${NOVA_DIR:?NOVA_DIR 未设置}"

# ---------- 1. 定位 drivers 目录 ----------
if [ -d "$GKI_ROOT/common/drivers" ]; then
    DRIVER_DIR="$GKI_ROOT/common/drivers"        # AOSP GKI 结构
elif [ -d "$GKI_ROOT/drivers" ]; then
    DRIVER_DIR="$GKI_ROOT/drivers"               # 常规内核结构
else
    echo "[ERROR] 未找到 drivers/ 目录（看了 common/drivers 和 drivers）"
    exit 127
fi
DRIVER_MAKEFILE="$DRIVER_DIR/Makefile"
DRIVER_KCONFIG="$DRIVER_DIR/Kconfig"
echo "[+] 使用 drivers 目录: $DRIVER_DIR"

# ---------- 2. 预清理（幂等） ----------
if [ -L "$DRIVER_DIR/kernelsu" ]; then
    rm "$DRIVER_DIR/kernelsu" && echo "[-] 移除旧软链"
fi
if [ -e "$GKI_ROOT/KernelSU" ]; then
    rm -rf "$GKI_ROOT/KernelSU"
    echo "[-] 清理旧 KernelSU 目录"
fi

# ---------- 3. 放置 Nova 源码 ----------
cp -r "$NOVA_KERNEL_DIR" "$GKI_ROOT/KernelSU"
# 防止把 .git 带进内核树（省空间 & 避免打扰内核的 git 检出状态）
rm -rf "$GKI_ROOT/KernelSU/.git"
echo "[+] Nova kernel 源码 -> $GKI_ROOT/KernelSU"

# ---------- 4. 软链 kernelsu -> KernelSU ----------
# 用绝对路径建软链：不依赖 `realpath --relative-to`（GNU 扩展，busybox 无）
ln -sfn "$GKI_ROOT/KernelSU" "$DRIVER_DIR/kernelsu"
[ -e "$DRIVER_DIR/kernelsu/Kconfig" ] || { echo "::error::软链建立失败"; exit 1; }
echo "[+] 软链建立: $DRIVER_DIR/kernelsu -> $GKI_ROOT/KernelSU"

# ---------- 5. Makefile 条目 ----------
if grep -q "kernelsu" "$DRIVER_MAKEFILE"; then
    echo "[=] Makefile 已有 kernelsu 条目，跳过"
else
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_MAKEFILE"
    echo '[+] Makefile 已添加 obj-$(CONFIG_KSU) += kernelsu/'
fi

# ---------- 6. Kconfig 条目 ----------
if grep -q "drivers/kernelsu/Kconfig" "$DRIVER_KCONFIG"; then
    echo "[=] Kconfig 已有 kernelsu 条目，跳过"
else
    if grep -q "^endmenu$" "$DRIVER_KCONFIG"; then
        sed -i "/^endmenu$/i\source \"drivers/kernelsu/Kconfig\"" "$DRIVER_KCONFIG"
    else
        printf "\nsource \"drivers/kernelsu/Kconfig\"\n" >> "$DRIVER_KCONFIG"
    fi
    echo "[+] Kconfig 已添加 source drivers/kernelsu/Kconfig"
fi

echo "[+] SukiSU Nova 集成完成"
echo "    CONFIG_KSU 将由 defconfig 控制（y=内置 / m=模块）"