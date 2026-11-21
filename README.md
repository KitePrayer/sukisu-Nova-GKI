# SukiSU Nova 自定义内核构建（GitHub Actions）

在 GitHub Actions 上，用**你自己指定的内核源码链接**编译 Android 内核，并集成
[SukiSU Nova](https://github.com/SukiSU-Nova/SukiSU-Nova)（KernelSU 官改版，含
KPM 模块支持）。

> 设计参考 [moemoli/GKI_KernelSU_SUSFS](https://github.com/moemoli/GKI_KernelSU_SUSFS)
> 的 build.yml。与原模板的关键区别：
>
> | | GKI_KernelSU_SUSFS | 本模板 |
> |---|---|---|
> | 内核源码 | 固定从 AOSP manifest 拉 Google 官方 GKI | **任意 git 链接 / 分支 / 子目录** |
> | KSU 变体 | SukiSU-Ultra（旧仓库） | **SukiSU Nova**（新仓库，含 NyaZygisk） |
> | 集成方式 | 官方 setup.sh（非标准端口镜像源） | clone GitHub + 等价位集成（软链驱动） |
> | defconfig | 固定 gki_defconfig | **任意 defconfig，可追加配置** |

## 快速开始

1. **Fork** 本仓库到你的 GitHub 账号。
2. 打开仓库 **Actions** 页 → 左侧 **Build Kernel (SukiSU Nova)** → **Run workflow**。
3. 填写必填参数：
   - `kernel_source_url`：内核源码 git 地址（HTTPS，如 `https://github.com/xxx/android_kernel_xxx.git`）
   - `kernel_source_branch`：分支 / tag / commit。**留空即可**，留空走仓库默认分支
   - `defconfig`：如 `gki_defconfig`、`vendor_defconfig`、`munch_defconfig`
4. 点 **Run workflow**，等编译完成（GKI 内核约 15–40 分钟）。
5. 到本次 run 的 **Artifacts** 下载产物：
   - `Image` / `Image.gz` / `Image.lz4`：内核镜像
   - `AnyKernel3-*.zip`：TWRP / 自刷 Recovery 可刷的刷机包（默认启用）
   - `kernel-version.txt`：内核版本标识

## 参数说明

### 内核源码

| 参数 | 说明 |
|---|---|
| `kernel_source_url` | 源码 git 地址，**必须**以 `.git` 结尾或能被 `git clone` 直接使用 |
| `kernel_source_branch` | 分支 / tag / commit 的任意一个。**留空 = 用仓库默认分支**（推荐）。填了但不存在时，工作流会先把该仓库所有分支和 tag 列出来再报错，不会只给你一个 exit 128 |
| `kernel_source_dir` | 源码在仓库中的子目录（如 `kernel/`、`common/`；根目录留空） |
| `defconfig` | defconfig 文件名，如 `gki_defconfig`。**必须以 `defconfig` 结尾**（kbuild 的 `make %config` 规则要求） |
| `defconfig_path` | defconfig 目录，默认自动搜索 `arch/arm64/configs`、`.../gki/`、`.../vendor/`；也可填自定义目录（如 `arch/arm64/configs/vendor2`） |
| `extra_defconfig` | 追加到 `.config` 的额外配置行，**每行一条**（也支持写 `\n` 分隔）。空行和 `#` 开头的行会被跳过 |

### SukiSU Nova

| 参数 | 说明 |
|---|---|
| `nova_source` | Nova 仓库 `owner/repo`，默认官方 `SukiSU-Nova/SukiSU-Nova`，可填你的 fork |
| `nova_branch` | `main`（kprobe 方案，`CONFIG_KSU` 可编成模块）或 `builtin`（纯内置 hook） |
| `nova_ref` | tag / commit，留空 = 分支最新 |

> **两个分支的实质差别**（已核对上游 Kconfig）：
> - `main`：`config KSU` 是 **tristate**，`depends on KPROBES && EXT4_FS`，
>   所以能编成 `=m` 模块（GKI LKM 模式）。
> - `builtin`：`config KSU` 是 **bool**，不需要 KPROBES，只能内置 `=y`。
>   若在 builtin 分支勾了 `ksu_as_module`，脚本会告警提示会被规整为 `y`。

### 编译选项

| 参数 | 说明 |
|---|---|
| `enable_kpm` | 启用 KPM 模块支持（`CONFIG_KPM=y`，64 位） |
| `ksu_as_module` | 把 KernelSU 编成模块（`CONFIG_KSU=m`，需要内核支持 GKI LKM） |
| `use_gcc` | 同时使用 GCC 交叉编译器（老内核 / 厂商源码需要 `CROSS_COMPILE`） |
| `gcc_url` | GCC 交叉编译器 git 地址，默认 LineageOS aarch64 6.4.1 |
| `toolchain_clang` | Clang 版本（见下方「工具链」） |

### 产物

| 参数 | 说明 |
|---|---|
| `pack_anykernel` | 默认 true，打包 AnyKernel3 刷机 zip |
| `anykernel_repo` | AnyKernel3 模板仓库，默认 `osm0sis/AnyKernel3`；GKI 内核可换 `WildKernels/AnyKernel3` 的 `gki-2.0` 分支 |
| `release_tag` | 非空时发布到 GitHub Release |

## 工具链

- **Clang**：默认从 [ZyCromerZ/Clang](https://github.com/ZyCromerZ/Clang) 的
  GitHub Release 下载（`15.0.7-20260208-release`，约 580MB）。要换版本填任意
  release tag，如 `16.0.6-20260807-release`、`23.0.0git-20260130-release`。
  > 工作流用 GitHub API 查 asset 真实下载地址，而不是拼 URL —— 因为该仓库
  > 的 **tag 名和文件名不一致**（tag `xxx-release`，文件 `Clang-xxx.tar.gz`）。
  >
  > 为什么不用 AOSP googlesource：它是 LFS 存储，国内网络经常拉不动；
  > ZyCromerZ 的包是完整 tar.gz，社区大量内核 Action 在用，可靠性高。
- **GCC**（可选）：LineageOS 预编译交叉编译器（默认 6.4.1），只在
  编译不支持 clang 的老内核时开 `use_gcc`。注意 6.4.1 较老，新内核
  通常用 clang 即可，无需开这个。

## 常见问题

### 1. 编译报错找不到 `clang` / `llvm-ar`
确认 `toolchain_clang` 填的是 ZyCromerZ 的 release tag，或留空用默认值。该包内含
完整 `bin/`（clang、llvm-ar、ld.lld 等）。

### 2. `CONFIG_KSU` 没有出现在 `.config`
- Nova 的 Kconfig 在 `drivers/kernelsu/Kconfig`，通过 `drivers/Kconfig` 的
  `source` 引入。若你的内核没走 `make <defconfig>` 而是用 `defconfig` 分片
  （fragment），检查 `extra_defconfig` 或内核的 fragment 机制把 `CONFIG_KSU=y`
  带进去。
- 用 `main` 分支必须满足 `CONFIG_KPROBES=y && CONFIG_EXT4_FS=y`（脚本已自动追加）。

### 3. 老内核（5.4 / 4.19）编译失败
- 需要 `use_gcc=true`：老内核经常没有 clang 支持。
- Nova `main` 分支对老内核可能不兼容，优先用 `builtin` 分支。
- AnyKernel3 默认模板是给新内核的，老内核请换对应内核版本的 AnyKernel3 分支。

### 4. 编译产物在哪个目录
`out/` 目录（即 Actions run 的 **Artifacts**），包含 `Image*` 和刷机包。

### 5. 找不到 vendordefconfig
`defconfig_path` 填实际目录，如 `arch/arm64/configs/vendor`。

## 目录结构

```
.
├── .github/workflows/build-kernel.yml   # 主工作流（全部参数入口）
├── scripts/
│   ├── ksu-integrate.sh                 # Nova 集成（软链 drivers/kernelsu）
│   └── build-kernel.sh                  # 编译 + defconfig + 打包
└── README.md
```

## 如何改成「编译 Google 官方 GKI」

不需要。直接填：
- `kernel_source_url` = `https://android.googlesource.com/kernel/common`
  （或先 `git clone` 到本地再推到你的仓库）
- `kernel_source_branch` = `android13-5.15` 等
- `defconfig` = `gki_defconfig`

## 免责声明

- 编译出的内核仅供学习研究。刷机有风险，请确保你了解你的设备分区结构
  （GKI 设备刷 boot 分区、非 GKI 设备用 AnyKernel3 包）。
- 内核可能触发设备防回滚 / 验证失败，自行承担风险。