import AppKit

/// Deferred native windows only: no visible UI, modal sessions or user input.
@main struct WindowPresentationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let browser = window(level: .floating), bridge = window(level: .statusBar)
        let settings = window(level: .floating), sheet = window(level: .floating)
        browser.addChildWindow(sheet, ordered: .above)
        let originalSheetLevel = sheet.level
        let dialog = window(level: .normal), nestedDialog = window(level: .normal)
        let unrelated = window(level: .floating)
        HubWindowPresentation.backgroundWindows = { [browser, bridge, settings, browser] }
        var modalChanges: [Bool] = []
        HubWindowPresentation.modalStateDidChange = { modalChanges.append($0) }
        expect(!HubWindowPresentation.isPresentingDialog, "No active modal initially")
        let response = HubWindowPresentation.withModalWindow(dialog) {
            expect(HubWindowPresentation.isPresentingDialog, "Modal scope must suppress background activation")
            expect(browser.level == .floating && bridge.level == .statusBar && settings.level == .floating,
                   "A picker must preserve all browser/background levels")
            expect(dialog.level.rawValue > [browser, bridge, settings, sheet].map { $0.level.rawValue }.max()!,
                   "The picker must rise above every background and sheet")
            expect(unrelated.level == .floating, "Unregistered windows remain unchanged")
            let parentLevel = dialog.level
            HubWindowPresentation.withModalWindow(nestedDialog) {
                expect(nestedDialog.level.rawValue > parentLevel.rawValue && dialog.level == parentLevel,
                       "Nested modal rises above its parent without demoting it")
                expect(HubWindowPresentation.isPresentingDialog, "Nested scope remains active")
            }
            expect(dialog.level == parentLevel && nestedDialog.level == .normal, "Nested completion restores levels")
            expect(HubWindowPresentation.isPresentingDialog, "Outer scope remains active")
            return 42
        }
        expect(response == 42 && !HubWindowPresentation.isPresentingDialog, "Result and scope restoration")
        expect(browser.level == .floating && bridge.level == .statusBar && settings.level == .floating,
               "Completion preserves exact background levels")
        expect(sheet.level == originalSheetLevel && dialog.level == .normal, "Child and picker levels restore")
        expect(modalChanges == [true, false], "Only outermost transitions suspend and resume shortcuts")
        enum ExpectedError: Error { case cancelled }
        do {
            try HubWindowPresentation.withModalWindow(dialog) { throw ExpectedError.cancelled }
            preconditionFailure("Expected propagation")
        } catch ExpectedError.cancelled {} catch { preconditionFailure("Unexpected error") }
        expect(!HubWindowPresentation.isPresentingDialog && dialog.level == .normal && bridge.level == .statusBar,
               "Error unwinding restores both scope and levels")
        expect(modalChanges == [true, false, true, false], "Error unwinding resumes shortcuts")

        browser.level = HubWindowPresentation.browserLevel(embedded: true)
        let embeddedFrame = browser.frame
        settings.level = HubWindowPresentation.auxiliaryLevel(above: browser.level)
        expect(browser.level == .statusBar && settings.level.rawValue > browser.level.rawValue,
               "Settings rise above embedded chrome while it protects the menu bar")
        HubWindowPresentation.withModalWindow(dialog) {
            expect(browser.level == .statusBar && browser.frame == embeddedFrame && dialog.level.rawValue > settings.level.rawValue,
                   "File dialogs keep embedded position, size and menu protection unchanged")
        }
        expect(browser.level == .statusBar && browser.frame == embeddedFrame, "Completion cannot move embedded chrome")
        expect(HubWindowPresentation.previewLevel(browserLevel: .statusBar).rawValue > NSWindow.Level.statusBar.rawValue,
               "Quick Look stays above embedded chrome")
        expect(HubWindowPresentation.previewLevel(browserLevel: .floating) == .floating &&
               HubWindowPresentation.browserLevel(embedded: false) == .floating &&
               HubWindowPresentation.auxiliaryLevel(above: .floating) == .floating,
               "Detached presentation keeps ordinary floating ordering")

        let managed = window(level: .normal), color = window(level: .floating)
        let coordinator = HubAuxiliaryWindowLevels(), managedFrame = managed.frame
        for _ in 0..<5 {
            coordinator.synchronize([managed, color, managed], above: .statusBar)
            expect(managed.level.rawValue > NSWindow.Level.statusBar.rawValue && color.level == managed.level,
                   "Settings/color/update windows rise without duplicate snapshots")
            expect(managed.frame == managedFrame && browser.frame == embeddedFrame,
                   "Level changes never move or resize any window")
            HubWindowPresentation.withModalWindow(dialog) {
                coordinator.synchronize([], above: .floating)
                expect(managed.level.rawValue > NSWindow.Level.statusBar.rawValue,
                       "Synchronization cannot interfere with an active modal owner")
            }
            coordinator.synchronize([managed, color], above: .floating)
            expect(managed.level == .floating && color.level == .floating, "Detachment removes high elevations")
            coordinator.synchronize([], above: .floating)
            expect(managed.level == .normal && color.level == .floating, "Session completion restores exact original levels")
        }
        coordinator.synchronize([managed], above: .statusBar)
        managed.level = .popUpMenu
        coordinator.synchronize([], above: .floating)
        expect(managed.level == .popUpMenu, "Restoration cannot overwrite another owner's change")
        expect([browser, bridge, settings, sheet, dialog, nestedDialog, unrelated, managed, color].allSatisfy { !$0.isVisible },
               "Tests must not display UI")
        HubWindowPresentation.backgroundWindows = nil
        HubWindowPresentation.modalStateDidChange = nil
        browser.removeChildWindow(sheet)
        print("PASS: embedded position/menu protection unchanged, auxiliary/color/update elevation, exact restoration, nested/error modal ordering, external-owner isolation and no visible test windows")
    }
    @MainActor private static func window(level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.level = level; window.isReleasedWhenClosed = false
        return window
    }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
}
