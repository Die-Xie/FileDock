# FileDock 1.30.3

- 修复文件名已截断但悬停没有提示的问题。SwiftUI 可能把原生文字层的可见区域扩大为整个文件窗口，现在跟踪范围明确限制在文字自身及其可见交集内。
- 显式接收鼠标移动事件，文件名区域重建后无需移出再移入即可恢复提示；稳定布局不再反复注册同一跟踪区域。
- 保留仅对被截断名称显示、提示跟随鼠标、自动避让屏幕边缘，以及点击／拖动／滚动／编辑时收起的行为。
- 截断测量按名称、字体、行数和尺寸缓存，鼠标移动不会反复排版或读取磁盘。

## English

- Fixes missing tooltips for truncated filenames. SwiftUI can report a native text overlay's visible rectangle as the entire browser, so tracking is now explicitly bounded to the visible part of the filename itself.
- Enables mouse-move delivery and recovers after tracking-region replacement without requiring the pointer to leave and re-enter. Stable layouts retain their existing tracking region.
- Retains tooltips only for truncated names, pointer-following placement, screen-edge clamping, and dismissal during clicking, dragging, scrolling, or editing.
- Caches truncation measurements by name, font, line count, and size; pointer movement does not repeat text layout or read files.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
