# FileDock 代码质量与性能 Review — 2026-10-24

基线：本地发布版本 1.14.1/build19。本轮检查源代码、异步任务与资源生命周期，并使用隔离文件和模拟后端验证，不修改用户文档或音乐播放状态。性能数字来自本机测试，不代表屏幕帧率。

## 本轮已修复

| 优先级 | 问题与影响 | 修复 |
| --- | --- | --- |
| P1 | 书签持续累积，写入配置可能超过读取器的 16 MiB 上限，导致下次启动无法读取自产配置 | 回收无引用书签；保留工作区、当前路径、历史、自定义图标和转移中的授权；超限时保留原配置并报告错误 |
| P2 | 批量暂存逐项编码并原子写入整份配置，主线程成本接近二次增长 | 嵌套保存事务，批量操作合并落盘 |
| P2 | 每两秒在主线程扫描目录，大目录可卡住输入与动画 | 定时扫描移到后台；单请求合并、取消检查、目录上下文与代次验证，防止旧结果覆盖新目录 |
| P2 | Finder 修改文件夹颜色、标签或图标后，旧快照只比较内容时间，未刷新外观 | 比较属性修改时间、标签与所有显示字段，保留亚秒精度；使用系统有效图标，按版本更新有容量限制的位图缓存 |
| P2 | 调整窗口大小时，每个通知分别保存宽度和高度 | 一次更新宽高，拖动期间延后保存，结束或退出强制保存 |
| P2 | 音乐被动轮询期间点击控制按钮被静默丢弃 | 首次点击取代旧轮询结果，沿同一串行队列执行；保留防连点、隐藏取消和进程校验 |
| P2 | 带 EXIF 旋转或镜像的照片导入后方向丢失 | 在原尺寸内变换像素，输出统一方向；覆盖 1–8 全部方向 |
| P2 | 图片解码在后台，但文件名探测和 PNG 写入仍阻塞主线程 | 目标确认后在后台完成写入，主线程只发布结果 |
| P2 | `/private/var` 路径别名可能让成功转移的暂存项未清除 | 标准化转移结果路径后匹配和移除 |
| P2 | 暂存根目录只接收文件 URL，原始图片被误判为需要真实文件夹 | 统一接收文件引用、原始图片、网页图片和临时文件表示；临时数据在回调有效期内持久保存，批次串行处理 |
| P3 | 仅快捷键模式或关闭全屏例外时仍持续探测前台窗口 | 按自动触发和全屏检测需求启停 AX 轮询，拒绝旧策略回包 |

同时将批量文件的父子项过滤从两两比较改为目录集合与祖先查询。图标缓存的实际像素限定为 256×256，避免系统多分辨率图标族占满缓存后立即被驱逐。

## 基准

使用相同脚本、Release 优化构建、各自独立的 500 个真实临时空文件，测试实际 `HubModel.stageFiles`：

| 项目 | 基线 | 修复后 |
| --- | ---: | ---: |
| 暂存 500 项 | 3.2252 秒 | 0.2135 秒 |
| 清空后的配置 | 641,709 字节 | 1,443 字节 |

该单次端到端测试约快 15.1 倍。它包含书签创建和保存，未把单独 JSON 编码时间当成整次操作耗时。基线与修复后的文件路径长度相近，缓存和系统负载仍会影响绝对值。

另以旧读取逻辑扫描 4,000 个临时空文件，仅元数据读取耗时 259–275ms。这些定时工作现移至后台，并未宣称磁盘本身变快。

可用相同逻辑复测当前版本的暂存操作；脚本只创建隔离临时文件，并在结束后清理：

```sh
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library Sources/HubModel.swift Sources/DirectoryLoader.swift Sources/FileAppearance.swift Sources/RecentFiles.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift scripts/BenchmarkStaging.swift -o .build/benchmark-staging -framework AppKit -framework Combine -framework Carbon -framework UniformTypeIdentifiers
.build/benchmark-staging
```

## 尚未修改的发现

1. **P2：重命名父目录没有即时迁移所有子路径引用。** `Sources/HubModel.swift` 的 `rename` 目前仅按被重命名路径精确匹配引用；其他合集引用其子文件时可能暂时失效，当前路径和历史也可能保留旧前缀。建议复用 `relocateReferences`，并补父目录、符号链接和历史导航的回归测试。
2. **P2：普通文件夹的网页图片下载没有全局并发或总内存限制。** `Sources/HubView.swift` 的 `receiveWebImageDrop` 每个地址启动独立会话；单文件上限 32 MiB，但批量峰值仍随数量增加。换目录只阻止末端保存，未取消进行中的网络请求。新暂存入口已按批次串行处理；普通文件夹及跨批次还应引入全局队列、可取消任务及总内存预算。
3. **P2：Spotlight 源的候选过滤仍可能阻塞主线程。** 1.17.1 已将首次目录打开、显式导航、刷新及 FileEntry 信息提取统一移至有并发上限和超时的后台加载器，详情见 [卡死修复记录](HANG_DIAGNOSIS.md)。`RecentFiles.swift` 仍在主线程提取查询结果并检查文件元数据，显示上限 500 不等于最多检查 500 个候选。下一步需拆分元数据查询快照、后台验证与导航完成状态，同时保证选中项和历史行为。
4. **P3：派生列表和视图重建成本。** `visibleEntries` 反复排序、`stagedURLs` 反复标准化路径，音乐更新也可能使大块浏览视图重新求值。建议增加明确的派生缓存失效规则，并拆分音乐、工作区和文件列表的观察边界。`HubModel.swift`、`HubView.swift`、`AppMain.swift` 职责较多，适合分阶段拆分，不宜在同一轮性能修复中大范围重写。

## 验证边界

自动测试覆盖真实红→蓝自定义图标像素、标签和亚秒变化、配置回收与超限保护、后台扫描旧结果、批量写入次数、resize 保存、路径别名、音乐轮询点击和图片方向。没有借此宣称完成 GPU 帧率、所有外接显示器、云端/网络盘或真实游戏全屏的性能实测。

属性读取依据 Apple 的 [URLResourceValues.effectiveIcon](https://developer.apple.com/documentation/foundation/urlresourcevalues/effectiveicon) 和属性修改时间；没有用文档内容的 generation identifier 替代外观变化，因为它[不随扩展属性变化](https://developer.apple.com/documentation/foundation/urlresourcevalues/generationidentifier)。
