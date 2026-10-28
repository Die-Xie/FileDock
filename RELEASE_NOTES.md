# FileDock 1.30.1

- 新增「拖到刘海时阻止进入调度中心」，仅在真实刘海顶边局部过滤拖动，保留原触发位置、进入比例和延迟；其他位置与系统手势不变。
- 完整保留首次到达顶边和离开后重新进入的移动，只过滤已到顶后继续向外的推挤，避免 Finder 拖入时鼠标或拖动图标向下回弹。不改写鼠标坐标，不丢弃拖动或松手事件。
- 设置提供辅助功能授权状态、授权入口及失败重试；后台自动重试有次数上限。全屏／应用限制、设置／对话框、边角与仅快捷键模式沿用原来的准入规则。
- 补充多屏边界、连续拖动轨迹、相对位置对齐、释放与重入、输入事件完整性及权限失败回归。

开关位于「设置 → 呼出与交互 → 呼出方式」，默认开启，需要辅助功能权限。已有配置和工作区保留。

## English

- Add **Prevent Mission Control when dragging to the notch**, filtering drags only at the physical notch's top edge. Keep the existing activation position, pointer-entry threshold and delay; other locations and system gestures are unchanged.
- Preserve the complete first arrival and re-entry movement. Only filter further outward pressure once the pointer is already at the edge, avoiding the downward cursor or drag-image rebound when dragging from Finder. No cursor-coordinate rewriting or discarded drag/release events.
- Show Accessibility permission status, a permission-settings shortcut and explicit retry. Automatic retries are bounded, and existing full-screen, app restriction, dialog, corner and keyboard-only policies remain in effect.
- Add regression coverage for display boundaries, continuous drag traces, relative image alignment, release/re-entry, event integrity and permission failures.

The option is in **Settings → Activation → Open Panel**, is enabled by default and requires Accessibility access. Existing workspaces and settings are preserved.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. The release is signed and is not yet notarized by Apple.
