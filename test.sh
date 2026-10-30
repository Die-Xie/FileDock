#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build
swiftc -swift-version 5 -O -parse-as-library -module-cache-path .build/module-cache \
    Sources/NotchDragGuard.swift Tests/NotchDragGuardTests.swift -o .build/notch-drag-guard-tests \
    -framework AppKit -framework ApplicationServices -framework Combine
.build/notch-drag-guard-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/WorkspaceTabInsertion.swift Tests/WorkspaceTabInsertionTests.swift -o .build/workspace-tab-insertion-tests
.build/workspace-tab-insertion-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/FolderWorkspaceDropTests.swift -o .build/folder-workspace-drop-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/folder-workspace-drop-tests
UV_CACHE_DIR=.build/uv-cache uv run --no-project python scripts/check-localization.py
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/FinderFileActionTests.swift -o .build/finder-file-action-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers -framework ImageIO
.build/finder-file-action-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/LocalizationTests.swift -o .build/localization-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/localization-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/ModelTests.swift -o .build/model-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/model-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/PartialReferenceReorderTests.swift -o .build/partial-reference-reorder-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/partial-reference-reorder-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ConfigurationAdmissionTests.swift -o .build/configuration-admission-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/configuration-admission-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/WorkspaceShortcutOrderTests.swift -o .build/workspace-shortcut-order-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/workspace-shortcut-order-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/FileAppearanceTests.swift -o .build/file-appearance-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/file-appearance-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Sources/InterfaceMotion.swift Sources/ColorLabelFilter.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Tests/ModelTestSupport.swift Tests/ColorLabelFilterTests.swift -o .build/color-label-filter-tests \
    -framework AppKit -framework Carbon -framework Combine -framework SwiftUI -framework UniformTypeIdentifiers
.build/color-label-filter-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Sources/InterfaceMotion.swift Sources/ColorLabelFilter.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Tests/ColorLabelFilterLayoutTests.swift -o .build/color-label-filter-layout-tests \
    -framework AppKit -framework Carbon -framework Combine -framework SwiftUI -framework UniformTypeIdentifiers
.build/color-label-filter-layout-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/RecentFiles.swift Tests/RecentFilesSourceTests.swift -o .build/recent-source-tests
.build/recent-source-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/RecentFiles.swift Tests/BackgroundRecentsTests.swift -o .build/background-recents-tests
.build/background-recents-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/RecentWorkspaceTests.swift -o .build/recent-workspace-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/recent-workspace-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/StagingWorkspaceTests.swift -o .build/staging-workspace-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/staging-workspace-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/ImageImport.swift Tests/ImageImportTests.swift -o .build/image-tests \
    -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
.build/image-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/ImageImport.swift Sources/StagingImportStore.swift Tests/StagingImportTests.swift -o .build/staging-import-tests \
    -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
.build/staging-import-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/ImageImport.swift Sources/ImportActivity.swift Sources/WebImageLoader.swift Sources/StagingImportStore.swift Sources/StagingDropReceiver.swift Tests/StagingDropTests.swift -o .build/staging-drop-tests \
    -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics
.build/staging-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NotchMotion.swift Sources/NotchGeometry.swift Tests/NotchGeometryTests.swift -o .build/notch-geometry-tests \
    -framework CoreGraphics
.build/notch-geometry-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NotchMotion.swift Sources/HubGlassMaterial.swift Sources/NotchSurface.swift Tests/NotchSurfaceTests.swift -o .build/notch-surface-tests \
    -framework AppKit -framework QuartzCore
.build/notch-surface-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/HoverActivation.swift Sources/HoverCursor.swift Tests/HoverActivationTests.swift -o .build/hover-tests -framework AppKit
.build/hover-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/TriggerSuppression.swift Tests/TriggerSuppressionTests.swift -o .build/trigger-suppression-tests \
    -framework AppKit -framework ApplicationServices
.build/trigger-suppression-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/WindowAttachment.swift Tests/WindowAttachmentTests.swift -o .build/window-attachment-tests
.build/window-attachment-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/CornerPlacement.swift Tests/CornerPlacementTests.swift -o .build/corner-placement-tests
.build/corner-placement-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/WindowPresentation.swift Tests/WindowPresentationTests.swift -o .build/window-presentation-tests \
    -framework AppKit
.build/window-presentation-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/GlobalShortcutTests.swift -o .build/shortcut-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/shortcut-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/Localization.swift Sources/LocalizationCatalog.swift Sources/GlobalShortcuts.swift Sources/ShortcutRecorder.swift Tests/ShortcutRecorderLayoutTests.swift -o .build/shortcut-recorder-layout-tests \
    -framework AppKit -framework Carbon -framework SwiftUI
.build/shortcut-recorder-layout-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Tests/NativeFileDragTests.swift -o .build/native-drag-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/native-drag-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeWorkspaceDrag.swift Tests/NativeWorkspaceDragTests.swift -o .build/workspace-drag-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/workspace-drag-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeWorkspaceDrag.swift Sources/ShortcutReorderDrop.swift Tests/ShortcutReorderDropTests.swift -o .build/shortcut-reorder-drop-tests \
    -framework AppKit -framework SwiftUI
.build/shortcut-reorder-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/InterfaceMotion.swift Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Sources/NativeFileDrop.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Tests/InterfaceMotionTests.swift -o .build/interface-motion-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/interface-motion-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/WorkspaceHeaderLayout.swift Tests/WorkspaceHeaderLayoutTests.swift -o .build/workspace-header-tests
.build/workspace-header-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Sources/WorkspaceFileDrop.swift Tests/WorkspaceSpringLoadingTests.swift -o .build/workspace-spring-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/workspace-spring-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/InterfaceMotion.swift Sources/WorkspaceHeaderLayout.swift Sources/WorkspaceShortcut.swift Tests/WorkspaceShortcutTests.swift -o .build/workspace-shortcut-tests \
    -framework AppKit -framework SwiftUI
.build/workspace-shortcut-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Sources/MarqueeSelection.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Tests/MarqueeSelectionTests.swift -o .build/marquee-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/marquee-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/EmbeddedMusicLayout.swift Tests/EmbeddedMusicLayoutTests.swift -o .build/embedded-music-tests
.build/embedded-music-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/MusicMarquee.swift Tests/MusicMarqueeTests.swift -o .build/music-marquee-tests \
    -framework AppKit -framework SwiftUI -framework QuartzCore
.build/music-marquee-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/InlinePreviewPolicy.swift Tests/InlinePreviewTests.swift -o .build/inline-preview-tests
.build/inline-preview-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/MusicProgress.swift Sources/MusicPlayers.swift Sources/NetEaseMusicBackend.swift Sources/QQMusicController.swift Tests/QQMusicTests.swift -o .build/qqmusic-tests \
    -framework AppKit -framework Combine -framework ApplicationServices -framework Carbon
.build/qqmusic-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/MusicProgress.swift Sources/MusicPlayers.swift Sources/NetEaseMusicBackend.swift Sources/QQMusicController.swift Tests/MultiPlayerTests.swift -o .build/multi-player-tests \
    -framework AppKit -framework Combine -framework ApplicationServices -framework Carbon
.build/multi-player-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/InterfaceMotion.swift Sources/EmbeddedMusicLayout.swift Sources/MusicMarquee.swift Sources/QQMusicBar.swift Sources/MusicProgress.swift Sources/MusicProgressTrack.swift Sources/MusicPlayers.swift Sources/NetEaseMusicBackend.swift Sources/QQMusicController.swift Tests/MusicProgressTests.swift -o .build/music-progress-tests \
    -framework AppKit -framework SwiftUI -framework QuartzCore -framework Combine -framework ApplicationServices -framework Carbon
.build/music-progress-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/AirDrop.swift Tests/AirDropTests.swift -o .build/airdrop-tests \
    -framework AppKit -framework Combine
.build/airdrop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/AirDrop.swift Sources/AirDropFileDrop.swift Sources/FileDropBatch.swift Sources/ImportActivity.swift Tests/AirDropFileDropTests.swift -o .build/airdrop-file-drop-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework Combine
.build/airdrop-file-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/SharingWindowSuspension.swift Tests/SharingWindowTests.swift -o .build/sharing-window-tests \
    -framework AppKit
.build/sharing-window-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/ThumbnailWorkQueue.swift Sources/WorkspaceCustomIcon.swift Tests/WorkspaceCustomIconTests.swift -o .build/workspace-custom-icon-tests \
    -framework AppKit -framework SwiftUI -framework ImageIO -framework Combine
.build/workspace-custom-icon-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/DirectoryLoadingTests.swift -o .build/directory-loading-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/directory-loading-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -O -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/LargeDirectoryTests.swift -o .build/large-directory-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/large-directory-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/CrossWorkspaceDropTests.swift -o .build/cross-workspace-drop-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/cross-workspace-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/DropUndoTests.swift -o .build/drop-undo-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/drop-undo-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Sources/Clipboard.swift Sources/ClipboardShortcuts.swift Sources/ImportActivity.swift Sources/ImageImport.swift Sources/StagingImportStore.swift Sources/StagingDropReceiver.swift Sources/WebImageLoader.swift Tests/ModelTestSupport.swift Tests/ClipboardTests.swift -o .build/clipboard-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers -framework ImageIO
.build/clipboard-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Sources/Clipboard.swift Sources/ClipboardShortcuts.swift Sources/ImportActivity.swift Sources/ImageImport.swift Sources/StagingImportStore.swift Sources/StagingDropReceiver.swift Sources/WebImageLoader.swift Tests/ModelTestSupport.swift Tests/BackgroundFileWorkTests.swift -o .build/background-file-work-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers -framework ImageIO
.build/background-file-work-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Tests/ModelTestSupport.swift Tests/TrashDropTests.swift -o .build/trash-drop-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers
.build/trash-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Sources/NativeFileDrop.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Sources/AirDropDropPlan.swift Sources/AirDrop.swift Tests/NativeFileDropTests.swift -o .build/native-drop-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers -framework Combine
.build/native-drop-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/FileDropBatch.swift Tests/FileDropBatchTests.swift -o .build/file-drop-batch-tests
.build/file-drop-batch-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/UpdateRelaunchGate.swift Tests/UpdateRelaunchTests.swift -o .build/update-relaunch-tests
.build/update-relaunch-tests
TASK_SPARKLE="$(./scripts/fetch-sparkle.sh)"
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache -F "$TASK_SPARKLE" \
    Sources/UpdateRelaunchGate.swift Sources/SoftwareUpdate.swift Tests/UpdaterAPITests.swift -o .build/updater-api-tests \
    -framework AppKit -framework SwiftUI -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/updater-api-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/NativeFileDrag.swift Sources/NativeWorkspaceDrag.swift Sources/NativeFileDrop.swift Sources/FileDropFeedback.swift Sources/WorkspaceTabInsertion.swift Tests/NativeDropHostingTests.swift -o .build/native-drop-hosting-tests \
    -framework AppKit -framework SwiftUI -framework UniformTypeIdentifiers
.build/native-drop-hosting-tests
swiftc -swift-version 5 Sources/Localization.swift Sources/LocalizationCatalog.swift -parse-as-library -module-cache-path .build/module-cache \
    Sources/GlobalShortcuts.swift Sources/WindowPresentation.swift Sources/RecentFiles.swift Sources/FileAppearance.swift Sources/WorkspaceShortcutOrder.swift Sources/DropUndo.swift Sources/HubModel.swift Sources/FolderWorkspacePreparation.swift Sources/FinderFileActions.swift Sources/FolderArtwork.swift Sources/DirectoryLoader.swift Sources/FileThumbnail.swift Sources/ThumbnailWorkQueue.swift Sources/PresentationState.swift Sources/MenuBarIcon.swift Tests/RenderingContinuityTests.swift -o .build/rendering-continuity-tests \
    -framework AppKit -framework Carbon -framework Combine -framework UniformTypeIdentifiers -framework SwiftUI -framework QuickLookThumbnailing
.build/rendering-continuity-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache \
    Sources/FileNameTooltip.swift Tests/FileNameTooltipTests.swift -o .build/filename-tooltip-tests \
    -framework AppKit -framework SwiftUI
.build/filename-tooltip-tests
TASK_VIEW_TEST_SOURCES=(Sources/*.swift)
TASK_VIEW_TEST_SOURCES=("${TASK_VIEW_TEST_SOURCES[@]:#Sources/AppMain.swift}")
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/ModelTestSupport.swift Tests/ColorLabelDropTests.swift -o .build/color-label-drop-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/color-label-drop-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/ModelTestSupport.swift Tests/InlineRenameTests.swift -o .build/inline-rename-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/inline-rename-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/HeaderWindowDragTests.swift -o .build/header-window-drag-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/header-window-drag-tests
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/SettingsLayoutTests.swift -o .build/settings-layout-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/settings-layout-tests

swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/FolderTabNativeTests.swift -o .build/folder-tab-native-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/folder-tab-native-tests

swiftc -swift-version 5 -parse-as-library -module-cache-path .build/module-cache "${TASK_VIEW_TEST_SOURCES[@]}" \
    Tests/ModelTestSupport.swift Tests/FolderStyleEditorTests.swift -o .build/folder-style-editor-tests \
    -framework AppKit -framework SwiftUI -framework Combine -framework Carbon -framework Quartz \
    -framework QuickLookThumbnailing -framework ImageIO -framework ServiceManagement -framework UniformTypeIdentifiers -framework ApplicationServices \
    -F "$TASK_SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker "$TASK_SPARKLE"
.build/folder-style-editor-tests
