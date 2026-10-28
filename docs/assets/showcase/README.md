# FileDock native product showcases

These six documentation images are rendered from the production `HubView`, `HubNotchSurface`, native file icons and Quick Look preview. The interface is **not AI-redrawn**.

| Scene | 简体中文 | English |
| --- | --- | --- |
| Workspace | [workspace-zh-Hans.webp](workspace-zh-Hans.webp) | [workspace-en.webp](workspace-en.webp) |
| Staging | [staging-zh-Hans.webp](staging-zh-Hans.webp) | [staging-en.webp](staging-en.webp) |
| Preview and playback bar | [preview-zh-Hans.webp](preview-zh-Hans.webp) | [preview-en.webp](preview-en.webp) |

## Rendering

Run from the repository root:

```sh
./scripts/render-readme-showcase.sh
```

The renderer requires macOS 14.4 or later, Swift command-line tools, and `cwebp`. These images were rendered on macOS 26 using the native glass material. The script uses the repository's verified Sparkle dependency and compiles the production UI without `AppMain.swift`; it does not build or install a replacement application.

- Temporary demo files, PDFs and configuration live in a unique temporary directory and are removed afterwards.
- A fixture music backend supplies the clearly generic track and artist. It never contacts, launches or controls a real player.
- ScreenCaptureKit's **current-process-only** content API captures only the matching demo window. It does not request global screen recording or capture the user's other applications.
- The surrounding desktop backdrop, notch and minimal status strip are presentation framing. The file interface, controls, text, preview and glass material come from the actual app components.
- The native screenshots are exported at 2880 × 1920 and encoded as WebP for README loading. They use the app's supported icon-size and appearance settings.
- The documentation render does not modify production sources, the installed app, or the user's FileDock configuration.

Sources: [ReadmeShowcase.swift](../../../scripts/ReadmeShowcase.swift), [render-readme-showcase.sh](../../../scripts/render-readme-showcase.sh).

## Original background

[woodland.webp](woodland.webp) is original background artwork generated using the built-in **imagegen** tool on 2026-10-28. Only this background uses image generation; no generated UI mockup is used in the README.

Final background prompt:

> Generate a wallpaper background ONLY for a real macOS utility product presentation. Landscape 3:2, softly out-of-focus photographic woodland canopy and shadowed foliage. Rich near-black forest green and muted olive moss highlights, restrained slate-teal shadows. Very strong optical defocus, abstract bokeh with natural organic variation, no sharp leaves, no bright yellow spots, no white highlights, no large glowing orb, calm low contrast behind readable translucent dark UI. Subtle darker lower half and corners; gentle forest light in upper left and upper right, center kept quiet. Refined native desktop atmosphere. ABSOLUTELY NO interface, windows, panels, menu bars, text, glyphs, logos, computer hardware, framing, or watermarks. This is original background art, not a product screenshot.

The external style reference informed the desktop atmosphere and spacing only; its interface, text and artwork were not reused.
