# 发布 FileDock

此流程发布已在本机验证、使用现有固定证书签名的 `FileDock.app`。GitHub Actions 只校验并上传静态文件，不重新编译、签名或公证，也不接触本机私钥。源码放在 `main`；临时 `release-assets/vX.Y.Z` 分支仅包含 ZIP、校验文件、发布说明和源码提交号。

## 本机准备

1. 更新 `Resources/Info.plist` 的版本号和 build，完成测试、通用架构构建及本机界面验证。继续使用现有 `local.diexie.filedock` bundle ID 和固定证书；不要为发布创建新签名身份。
2. 对交付应用执行 `codesign --verify --deep --strict --all-architectures`，并使用 `sign.sh` 中相同的 designated requirement 核对固定证书和 bundle ID。确认 ZIP 内只有 `FileDock.app` 及其资源元数据，不包含配置、Signing 目录、证书备份、钥匙串或私钥。此处是实际签名验证；发布脚本不会在 Linux 上声称验证 macOS 信任或公证。
3. 将应用打包为 ZIP，准备独立的 UTF-8 `RELEASE_NOTES.md`。说明版本、关键变更、macOS 支持范围与未公证状态。ZIP 必须小于 95 MiB，以便通过临时 Git 分支上传。
4. 提交源码、工作流和必要文档后通过 SSH 推送到 `origin/main`。发布脚本要求工作树干净、`HEAD` 与远程 `main` 完全相同，且目标 tag、临时资源分支均不存在。ZIP 和发布说明放在仓库外或被忽略的构建目录中。

可先运行本地校验。此模式仍检查远程 refs，但不会创建 tag、更新 refs 或上传内容；它只会在本地对象库中留下未引用的校验用对象：

```sh
./scripts/publish-release.sh --dry-run /absolute/path/FileDock.zip /absolute/path/RELEASE_NOTES.md v1.15.0
```

确认输出的版本、源码提交和 SHA-256 后发布：

```sh
./scripts/publish-release.sh /absolute/path/FileDock.zip /absolute/path/RELEASE_NOTES.md v1.15.0
```

省略末尾 tag 时从 `Info.plist` 自动生成。当前流程只接受稳定版 `vX.Y.Z`，不接受预发布后缀。脚本使用普通 annotated tag（`git tag -a`），不需要 GPG。应用自身仍保留原有 macOS 代码签名。

## 上传与发布过程

脚本用独立的临时 `GIT_INDEX_FILE`、`git hash-object` 和无父提交的 `git commit-tree` 生成四文件资源树，不切换工作区、不修改真实索引，也不把二进制加入源码历史。资源分支先推送成功，再推送指向源码 `HEAD` 的 annotated tag；任何 push 都不带 force。

Tag 的 push 触发 `.github/workflows/release.yml`。Ubuntu runner 使用 GitHub 自动提供的 `GITHUB_TOKEN`，只获 `contents: write`，无需在本机登录 `gh` 或创建额外 PAT。工作流没有第三方 action，只 fetch 指定资源分支，从 Git blobs 读取固定文件，不执行资源分支代码或 checkout 过滤器。它检查：

- tag 格式、tag 指向的源码 commit 与 `SOURCE_COMMIT`/事件 commit 一致；
- 资源树仅有四个普通文件，SHA-256 清单完整且校验通过；
- ZIP 完整、内部应用名称和版本正确、bundle ID 保持不变；
- 同名 Release 或草稿尚不存在。

通过后先创建 draft，上传 `FileDock.zip`、`SHA256SUMS.txt`、`RELEASE_NOTES.md` 和 `SOURCE_COMMIT`，最后公开并设为 Latest。额外上传说明和提交号，使下载后的 `sha256sum --check SHA256SUMS.txt` 能验证清单中的全部文件。这里校验的是字节一致性，不能替代本机代码签名与运行验证。

## 成功后清理

在 GitHub Actions 与 Release 页面确认成功，下载 ZIP 及校验文件核对 SHA-256，再通过 SSH 删除临时资源分支：

```sh
git push origin --delete release-assets/v1.15.0
```

工作流不自动删除 refs。源码 tag、Release 附件及本机签名身份均保留。删除临时分支不会将资源提交并入 `main`。

## 失败恢复

失败时保留草稿和资源分支以便排查，不自动覆盖或删除。

- **资源分支 push 失败：** 未创建本地 tag。确认远程状态后处理网络或权限问题；已有分支必须先检查，不能直接 force。
- **tag push 失败：** 资源分支和本地 annotated tag 已存在。确认它仍指向预期源码后，单独运行 `git push origin refs/tags/v1.15.0:refs/tags/v1.15.0`；不要直接重新运行发布脚本。
- **工作流在创建草稿前失败：** 先查看 Actions 日志并核对四个文件。资源未改动、问题仅为暂时网络故障时，可重新运行同一次工作流。
- **已有 draft 或公开 Release：** 工作流明确拒绝覆盖。检查草稿中已有附件与校验值，人工补齐并发布，或明确删除错误草稿后再重跑；不使用 `--clobber`。不要移动已经公开的 tag。
- **校验或版本不符：** 停止发布并查明来源。使用正确的新版本号和新源码提交重新走流程；不通过重签名或更换 bundle ID 绕过校验。

GitHub 的相关行为见 [tag push 触发规则](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#push)、[工作流 GITHUB_TOKEN](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token)、[创建 Release](https://cli.github.com/manual/gh_release_create) 和 [编辑 Release](https://cli.github.com/manual/gh_release_edit)。
