# FileDock 1.31.2

- 悬停切换改为跟随鼠标最终停留的目标。连续经过标签时只更新候选目标，短暂停稳后再切换，避免先进入中间工作区。
- 保留配置的悬停延迟，增加 50 ms 的最短指向稳定判定，并容忍微小抖动；0 ms 仍关闭普通悬停切换。
- 修复切换后的标签自动滚动取消下一次悬停计时的问题。悬停目标已在视口内，不再重复滚动或重置指针基准；点击和键盘仍保留标签展示。
- 选中背景使用可连续衔接的近临界阻尼弹簧过渡；标签位置、文件区和原生拖放命中区域保持稳定，减少动态重排。
- 鼠标移动只更新不发布界面变化的控制器，停稳后才选择工作区；不增加轮询，不为经过的中间标签触发文件加载。保留 30 点宽、4 点间距。

## English

- Hover switching follows the final destination. Moving across tabs only updates the candidate; selection waits for a brief pause, avoiding intermediate workspaces.
- Retains the configured delay with a minimum 50 ms pointer-settling check and small-jitter tolerance. A zero delay still disables ordinary hover switching.
- Fixes selection scrolling cancelling the next hover timer. Visible hover targets no longer repeat reveal scrolling or reset the pointer baseline. Click and keyboard selection still reveal their tabs.
- Uses a retargetable, nearly critically damped spring for the selection backdrop. Labels, file content and native drag hit regions keep stable geometry.
- Pointer movement updates a non-publishing controller; only a settled selection changes the workspace. Adds no polling and avoids file loads for pass-through tabs. Keeps 30-point icon widths and 4-point gaps.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
