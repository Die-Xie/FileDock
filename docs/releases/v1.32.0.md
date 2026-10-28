# FileDock 1.32.0

- 底部新增颜色标签筛选，支持访达七种颜色、“无颜色”和“全部”。再次点击当前颜色可清除筛选，筛选可与名称搜索叠加。
- 底部不再重复显示路径，顶部路径导航保留。窗口较窄时筛选自动收纳为菜单。
- 在「设置 → 文件 → 浏览与排序」中可开关颜色筛选；关闭后清除筛选并恢复全部项目。切换工作区或目录也会清除筛选。
- 三种文件视图、收藏与暂存等合集共用筛选结果。颜色变化刷新后同步更新，筛选不修改标签、原文件或手动顺序。
- 复用后台加载的颜色元数据和现有排序缓存，不新增文件读取、目录刷新或轮询；当前筛选不写入配置。

## English

- Filter by the seven Finder color labels, No Color, or All in the footer. Click the selected color again to clear it; color and name filters work together.
- Removes the repeated footer path while keeping breadcrumb navigation. Narrow windows use a compact filter menu.
- Toggle the filter in Settings → Files → Browsing & Sorting. Disabling it or changing folders/workspaces clears the active color filter.
- Grid, list, columns, and reference collections share the filtered results. Refreshed label changes are reflected without changing files, tags, or manual ordering.
- Reuses loaded metadata and cached sorting. Adds no file reads, directory refreshes, or polling. The current filter is transient.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
