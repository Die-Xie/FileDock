# FileDock 1.33.0

- 扩大底部颜色按钮为完整的 28 × 28 点点击区域，圆点周围的留白也能点选，保持紧凑单行布局。
- 支持悬停选择颜色及“全部”，共用「悬停切换工作区」延迟，0 ms 关闭普通悬停选择。鼠标停稳后应用筛选，离开、拖动、隐藏面板或关闭功能时取消等待。
- 文件可从 FileDock 或 Finder 拖到颜色按钮，松开后设置相应的访达颜色标签；拖到“无颜色”移除颜色。文件位置、内容、自定义标签及手动排列顺序保留。
- 颜色投放复用稳定的原生拖放接收器，并显示目标和松手提示。拖动时暂停悬停筛选；关闭颜色筛选后不再接受颜色投放。
- 悬停后的首次点击确认当前颜色，再次点击可清除；清除后不会因指针仍在原处立即重新选中。

## English

- Expands each color button to a full 28 × 28-point target, including padding around the dot, while keeping a compact single row.
- Hover over a color or All using the workspace-switch delay; 0 ms disables ordinary hover selection. Leaving, dragging, hiding the panel, or disabling the feature cancels pending selection.
- Drop files from FileDock or Finder on a color to apply its Finder label, or on No Color to remove it. Contents, locations, custom tags, and manual order are preserved.
- Uses the stable native drop destination with target and release feedback. Hover filtering pauses during drags; disabling color filtering also disables label drops.
- The first click after hover confirms the selection; a later click can clear it without hover immediately selecting it again.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
