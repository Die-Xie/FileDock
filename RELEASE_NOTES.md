# FileDock 1.31.0

- 「设置 → 呼出与交互 → 全屏与应用限制」新增应用白名单，可从运行中的应用或应用选择器添加、移除项目。
- 白名单应用无论是否全屏，都能使用当前正常的鼠标触发方式。白名单默认为空；未加入的应用继续遵守原来的全屏和黑名单规则，不会额外受到限制。
- 同一应用同时出现在黑名单与白名单时，以黑名单为准。白名单保留触发位置、副屏准入、刘海进入比例及悬停／点按偏好，不会启用「仅快捷键」模式下的鼠标触发。
- 悬停展开、刘海／边角点按、拖动返回和刘海拖动过滤使用相同的应用规则。全局快捷键和菜单栏始终可用。
- 应用名单在设置变化时缓存为集合，触发检查无需反复排序或构建名单；只使用已有的前台应用信息，不新增辅助功能授权或窗口轮询。

## English

- Adds an app whitelist in Settings → Activation → Full-screen & App Restrictions. Add or remove apps through the running-app menu or application picker.
- Whitelisted apps can use normal pointer activation whether or not they are in full screen. The list starts empty. Unlisted apps retain the existing full-screen and blocked-app rules, with no additional restrictions.
- If an app appears in both lists, the blocked-app rule takes priority. The whitelist preserves the chosen trigger area, secondary-display access, notch-entry threshold, and hover/click preference; it never enables pointer activation in Keyboard Only mode.
- Hover expansion, notch/corner clicks, drag return and notch drag filtering share the same app rules. Global shortcuts and the menu bar stay available.
- App rules are cached as sets when settings change, avoiding repeated sorting or list construction during trigger checks. Uses existing foreground-app information without additional Accessibility permission or window polling.

Requires macOS 13 or later. Universal build for Apple Silicon and Intel. Signed, not yet notarized by Apple. Existing settings and workspaces are preserved.
