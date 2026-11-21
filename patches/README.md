# patches/

放内核补丁的地方（当前工作流**不自动应用**这里的补丁，仅作占位约定）。

如果你想扩展流程，比如：

- **SUSFS4KSU**（隐藏 root 痕迹）：把 `susfs4ksu` 的 `kernel_patches/` 下
  对应内核版本的补丁放进这里，然后在 `scripts/build-kernel.sh` 的
  `make <defconfig>` 之前加一行：

  ```bash
  for p in "$GITHUB_WORKSPACE"/patches/*.patch; do
      patch -p1 < "$p" || { echo "::error::补丁 $p 应用失败"; exit 1; }
  done
  ```

- **厂商内核的编译修复补丁**

约定：

- 文件名以 `.patch` 结尾，`patch -p1` 可应用（相对内核根目录）。
- 按内核版本分子目录更清晰，如 `patches/5.15/`、`patches/6.1/`。
