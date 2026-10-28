<div align="center">

<img src="docs/assets/filedock-icon.png" width="88" height="88" alt="FileDock icon" />

# FileDock

[简体中文](README.md)　|　**English**

### Your files, within reach.

A native macOS file workspace tucked along the edge of your screen.<br />
Open it when you need it, stage files, and preview documents as you work.

**[Download FileDock](https://github.com/Die-Xie/FileDock/releases/latest)**　·　[User Guide (Chinese)](docs/GUIDE.md)　·　[Feedback & Issues](https://github.com/Die-Xie/FileDock/issues)

macOS 13+　 /　 Apple Silicon & Intel　 /　 Apache 2.0

</div>

![FileDock workspace illustration with frequently used folders, Favorites, Staging, and music controls](docs/assets/filedock-hero.png)

<p align="center"><sub>Illustrations use generic sample files and show the Chinese interface. The app supports English too; its appearance varies with your macOS version, theme, and layout settings.</sub></p>

## Keep everyday files close

Reference documents for a proposal, assets for a design, or downloads waiting to be sorted—give them a place in FileDock so you can find them when you need them.

Frequently used folders become separate tabs. Favorites keeps files from different locations together, and Recents takes you back to documents you opened recently. Arrange workspace order, icons, and view modes to suit your workflow.

Drag a folder from Finder or FileDock between the top tabs or to either end. Release when you see the blue insertion line and folder-plus icon to create a tab at that position. The original folder stays in place. Dragging over the center of an existing tab still switches workspaces or drops files into that workspace.

Switch instantly between Simplified Chinese and English in **Settings → General → Language**, or follow your system language.

## Open it when you need it

Move the pointer into the notch or a configured screen corner, and the workspace opens from that location. Keyboard shortcuts can also open it at the trigger location or beside your pointer.

- **Fit your screen:** choose a curved notch connection, an embedded notch layout, or one of the four screen corners.
- **Set your timing:** adjust opening and closing delays and animation speed. Notch activation also supports clicking instead of hovering.
- **Keep it on the desktop:** drag the panel out by an empty part of its header to pin it automatically while you organize files.
- **Stay focused:** block automatic activation for selected apps, such as games and video players, or pause pointer activation in full screen.

## Collect first, organize later

![Staging workflow: collect files and folders, then copy or move them to a destination folder](docs/assets/filedock-staging.png)

Gather files from several folders, or collect downloads before moving them into a project. Drag them into **Staging**, then drag them out again or copy or move the batch to a destination. Files, folders, and document packages are supported.

**Local files are staged as references. Clearing the list does not delete the originals.** Web images and temporary files supplied by other apps are saved locally before being staged. You can hide the Staging entry at any time without losing its contents.

## Browse, read, and control your music

![Column preview and music controls: read selected documents and reveal playback controls by hovering](docs/assets/filedock-browse-music.png)

Use the grid to browse images, the list to compare dates and sizes, or columns to explore folders. Select a file to preview it beside the list; images, PDFs, and text documents can be viewed directly. Press **Space** for Quick Look.

Right-click a folder to change its color label or add a symbol, emoji, or image icon. Changes also appear in Finder. The context menu includes **Get Info, Compress, Duplicate, Make Alias,** and **Open in Terminal**.

Keep **QQ Music, Apple's Music app, and NetEase Cloud Music** within reach. In **Settings → Music**, select a player or let FileDock choose the one that is playing. The embedded notch layout shows track information, scrolls long titles, and reveals playback controls on hover. Other layouts use a playback bar at the bottom. Music uses macOS Automation permission; QQ Music and NetEase Cloud Music use Accessibility permission. NetEase controls and track information depend on what its native menus and windows expose.

To send files to a nearby Apple device, drag them onto the **AirDrop** icon beside Favorites, or select files and click the icon. Choose a recipient in the system panel. You can also send a batch from Staging and turn the entry off in the **＋** menu or Settings.

New installations use Diexie's current preferences: Liquid Glass, the embedded notch layout, instant opening and closing, and 1.3× animation speed. Music, Favorites, Staging, and launch at login are enabled; files and folders are mixed and sorted by modification date, newest first. All of these settings can be changed, and existing configurations are preserved. Defaults contain no personal paths, bookmarks, or system permissions.

<sub>Preview formats depend on macOS Quick Look and installed extensions. Music connection status and reconnection controls are available in Settings → Music.</sub>

## Make it fit your workflow

| What you want | How FileDock helps |
| --- | --- |
| A desktop that feels right | Dark Liquid Glass, or a solid theme that follows light and dark appearance |
| Easier access to frequent files | Reorder workspace tabs and pinned icons, use icon-only tabs, and keep Favorites and Staging close |
| Direct file organization | Drag to reorder files, drag multiple selections, copy and paste, and use context menus |
| Faster navigation | Clickable breadcrumb paths, back and forward history, and ⌘↑ / ⌘↓ navigation |
| Control over your settings | Workspaces and preferences stay local, with configuration import and export |

No account is required. Workspace configuration stays on your Mac. FileDock includes no telemetry, subscription, or account service.

## Get started in three steps

1. **Download and install:** download `FileDock.zip` from the [latest release](https://github.com/Die-Xie/FileDock/releases/latest), extract it, and move `FileDock.app` into **Applications**.
2. **Add your everyday folders and files:** use **＋** to add a folder workspace or a collection of file references. Checkboxes in the same menu manage Favorites, Recents, Staging, and AirDrop. Hiding Favorites or Recents removes its entry entirely instead of turning it into a regular tab. Drag the function icons at the top right to reorder them.
3. **Choose how to open it:** select notch, corner, or keyboard activation in Settings. By default, **⌘⌥↓** opens the workspace at its trigger location, and **⌘⌥→** opens it beside your pointer. Both shortcuts can be reassigned.

Requires **macOS 13 or later**. Releases are universal builds for Apple Silicon and Intel. Liquid Glass uses the native effect on macOS 26 and a blurred material on earlier systems. The release is signed but **not yet notarized by Apple**. Starting with version 1.19, you can check for, download, and install updates from **Settings → About** or the menu bar. Earlier versions need a manual replacement of the same FileDock app in Applications first.

For staging rules, drag and drop, keyboard shortcuts, and music setup, see the **[User Guide (Chinese) →](docs/GUIDE.md)**.

<details>
<summary>Development, builds, and releases</summary>

FileDock is built with Swift, AppKit, and SwiftUI. This repository contains the source code, tests, and release tools. Compiled applications are available in Releases.

The following technical documents and release notes are currently in Chinese:

- [Build from source and sign the app](docs/BUILDING.md)
- [Release workflow](docs/RELEASING.md)
- [Code quality and performance review](docs/QUALITY_REVIEW.md)
- [Release notes](docs/releases/)

**1.30.0** adds folder styling, system color labels, and Finder operations including Get Info, Compress, Duplicate, Make Alias, and Open in Terminal. [Release notes](docs/releases/v1.30.0.md).

**1.29.0** lets you create folder tabs by dropping folders between tabs or at either end, with an insertion line and release prompt. [Release notes](docs/releases/v1.29.0.md).

**1.28.1** adds continuous adjustment of notch pointer entry. Values above 100% require the pointer to move farther inward after fully entering. [Release notes](docs/releases/v1.28.1.md).

**1.28.0** adds Chinese and English interface switching and clearer activation settings for full screen and blocked apps. [Release notes](docs/releases/v1.28.0.md).

**1.27.0** allows temporary click activation in full screen or a blocked app, then restores the normal activation mode when that restriction ends. [Release notes](docs/releases/v1.27.0.md).

**1.26.2** supports dragging files to the system Trash and removes corresponding references from Favorites and Staging. [Release notes](docs/releases/v1.26.2.md).

**1.26.1** lets the panel close when a file is dragged out, then reopen when the same drag returns to the notch or configured corner. [Release notes](docs/releases/v1.26.1.md).

**1.26.0** can hide the panel during an outgoing file drag to uncover the destination beneath it. This behavior can be disabled in Settings. [Release notes](docs/releases/v1.26.0.md).

**1.25.1** adds Finder-style inline renaming: Return / Enter edits the selected filename and preserves its extension by default. [Release notes](docs/releases/v1.25.1.md).

**1.25.0** adds clipboard pasting for files and images, including Favorites and Staging, and supports Ctrl+C / Ctrl+V in the file area. [Release notes](docs/releases/v1.25.0.md).

**1.24.0** adds real playback progress for Music, hides progress when timing data is unavailable, and adds Quit to the Settings sidebar. [Release notes](docs/releases/v1.24.0.md).

**1.23.0** removes novelty animations and reorganizes Settings with sidebar categories and consistent groups for activation delays and file shortcuts. [Release notes](docs/releases/v1.23.0.md).

**1.22.1** restores panel dragging across empty header areas and adds continuous workspace hover delay adjustment with millisecond values and a single save after adjustment. [Release notes](docs/releases/v1.22.1.md).

**1.22.0** improves selection transitions for tabs, pinned entries, and view modes; reduces brief loading flashes; and resumes music text scrolling from its previous position after hover. Animations stay within lightweight feedback layers while file drag destinations and geometry remain stable. [Release notes](docs/releases/v1.22.0.md).

**1.21.5** completes gap and end drop zones for pinned icons and regular tabs, keeping insertion guidance aligned with the final position. [Release notes](docs/releases/v1.21.5.md).

**1.21.4** fully hides Favorites when unpinned and adds drag reordering with saved order for the top-right function icons. [Release notes](docs/releases/v1.21.4.md).

**1.21.3** fully hides Recents when unpinned and adds an AirDrop toggle to the ＋ menu that stays in sync with Settings. [Release notes](docs/releases/v1.21.3.md).

**1.21.2** supports dropping files directly onto AirDrop and makes Recents a checkbox option in the ＋ menu. [Release notes](docs/releases/v1.21.2.md).

**1.21.1** moves the AirDrop shortcut beside Favorites and lets you pin Recents at the top right. [Release notes](docs/releases/v1.21.1.md).

**1.21.0** introduces multiple music players and AirDrop, and fixes lost references during reordering while loading, configuration import races, and folder recognition fallbacks. [Release notes](docs/releases/v1.21.0.md).

**1.20.1** further improves Recents, batched persistence, and background file operations. [Review notes](docs/releases/v1.20.1.md).

**1.20.0** improves batched loading, background sorting, and refresh costs for folders containing tens of thousands of items. Application previews show only icons and information. [Release notes](docs/releases/v1.20.0.md).

**1.18.0** adds marquee selection and workspace switching during file drags, and fixes clipped shortcuts and menu-bar overlap when opening Quick Look or Settings. [Release notes](docs/releases/v1.18.0.md).

**1.18.1** adds original SVG staging, Quick Look window-level fixes, and more efficient icon loading during drags in response to user feedback. [Release notes](docs/releases/v1.18.1.md).

**1.17.1** fixes hangs caused by synchronous directory scans during hover switching. Initial loading, workspace changes, path navigation, and refreshes all use background loading. The current version offers a retry after five seconds without read progress, while allowing workspace switching. At most three actual reads can remain unfinished; timeout or cancellation does not release a slot while its system call is still running. Periodic refresh does not repeatedly retry timed-out folders. [Diagnosis and tests](docs/HANG_DIAGNOSIS.md).

</details>

---

<p align="center">
Made by <a href="https://github.com/Die-Xie">Diexie</a><br />
<sub>Copyright © 2026 Diexie. · <a href="LICENSE">Apache License 2.0</a></sub>
</p>
