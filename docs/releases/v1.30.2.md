# FileDock 1.30.2

- 鼠标停在被截断的文件或文件夹名称上稍等，即可查看完整名称，包含扩展名、中文和 Emoji；完整显示的名称不弹出提示。
- 提示跟随鼠标移动，并自动避让屏幕边缘；点击、拖动、滚动或重命名时收起。
- 覆盖网格、列表、分栏、收藏及暂存；分栏上级目录和预览标题也按是否截断显示提示。
- 重命名后提示同步更新；原生文件交互层在编辑文件名时暂停自身提示，避免干扰输入。
- 使用单个原生提示浮层和鼠标事件，不新增悬停轮询或磁盘读取，保留原来的拖放和右键菜单行为。

## English

- Hover over a truncated filename to see its complete name, including its extension, Unicode characters, and emoji. Fully visible names show no tooltip.
- The tooltip follows the pointer, stays within the screen, and dismisses when clicking, dragging, scrolling, or renaming.
- Available in grid, list, columns, Favorites, and Staging, as well as parent-folder rows and preview titles.
- Tooltips update after renaming. The native file interaction layer suspends its tooltip while the filename editor is active.
- Uses one shared native popup and mouse events without additional hover polling or file reads, retaining existing drag-and-drop and context-menu behavior.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
