# 从源码构建 FileDock

[← 返回产品介绍](../README.md) · [使用指南](GUIDE.md) · [发布流程](RELEASING.md)

## 环境要求

需要 Swift 编译器，以及包含 AppKit 26 的 macOS SDK（Xcode 26 或对应 Command Line Tools）。应用运行目标仍为 macOS 13 及以上，不依赖第三方包或完整 Xcode 工程。

## 项目结构

```text
Sources/       原生应用、文件模型、拖放、预览、主题与音乐控制
Resources/     Info.plist、应用图标及图标生成源
Tests/         使用隔离文件和模拟后端的回归测试
scripts/       签名初始化与发布工具
docs/          使用指南、质量审查、发布说明及产品配图
.github/       Release 工作流
build.sh       构建并验证应用签名
test.sh        运行测试
```

构建产物、缓存、个人配置和签名私钥不进入源码仓库；编译好的应用通过 Release 提供。

## 构建与检查

在仓库根目录运行：

```sh
./setup-signing.sh      # 首次建立本机固定签名身份，之后校验并复用
./build.sh              # 当前机器架构
./build.sh --universal  # Apple Silicon + Intel
./test.sh               # 运行回归测试
./test-signing.sh       # 验证跨构建身份，以及对错误身份的拒绝
```

产物位于 `build/FileDock.app`。安装时退出旧应用，替换 `/Applications/FileDock.app`，避免额外的可启动副本。当前发行包使用固定本地证书签名，尚未进行 Apple 公证。

## 保持签名身份稳定

应用标识保持为 `local.diexie.filedock`。本机更新应复用已有证书与 bundle ID；更换身份可能导致 macOS 要求重新授权辅助功能。

签名私钥保存在当前用户的登录钥匙串中，设为敏感、不可导出，并仅允许系统 `/usr/bin/codesign` 使用。公共证书与身份配置位于：

```text
~/Library/Application Support/FileDock/Signing/
```

这些文件不放入源码或应用包。Signing 配置不包含私钥，不能单独用于恢复签名身份。

构建流程同时核对 bundle ID 与固定证书指纹。初始化不会添加系统根信任；身份缺失或配置不一致时会停止，不自动生成新身份，也不退回临时签名。有关系统机制可参考 Apple 的[代码身份与更新要求](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

从临时签名迁移到固定证书，或应用标识发生变更时，可能需要一次新的授权。后续使用相同身份更新可沿用该身份；更换电脑、丢失钥匙串私钥或重置系统隐私权限后，仍可能需要重新授权。

## 数据位置

```text
~/Library/Application Support/FileDock/config.json
~/Library/Application Support/FileDock/Staged Imports/
~/Library/Application Support/FileDock/Signing/
```

配置包含工作区路径、书签与偏好，权限为 `0600`。暂存区对本地文件保存引用；原始图片与临时文件的导入内容保存在 `Staged Imports`。系统最近文件查询结果只在内存中，不写入配置或导出文件。

## 文档与配图

README 的产品配图位于 `docs/assets/`。PNG 用于直接展示，SVG 是可编辑源；它们使用通用示例内容绘制，属于功能与界面示意，并非运行截图。应用图标取自 `Resources/AppIcon.icns`。

用户操作说明见[使用指南](GUIDE.md)，发布步骤见[发布流程](RELEASING.md)，历史审查结论见[质量与性能审查记录](QUALITY_REVIEW.md)。
