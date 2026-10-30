# FileDock 1.34.1

- 将文件拖入颜色筛选结果时，为接收的项目设置对应的 Finder 颜色标签；拖入子文件夹保持原有行为。
- 将文件拖到颜色入口时，当前文件夹外的项目会移入该文件夹并设置颜色，按住 Option 可复制；当前文件夹内的项目只更新颜色。
- 颜色相关拖放支持 ⌘Z 撤销可安全验证的项目及新增引用。复制项目撤销时移到废纸篓；遇到文件变更、路径冲突或验证上限时提示并保留项目。

## English

- Apply the selected Finder color when dropping items into a color-filtered view; drops into a subfolder retain their normal behavior.
- Dropping outside items onto a color moves them into the current folder and applies the color; hold Option to copy. Items already in the folder are labeled in place.
- Use Command-Z to undo safely verifiable color drops and newly added references. Copied items are moved to the Trash; changed items, path conflicts, and verification limits are reported without forcing a rollback.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
