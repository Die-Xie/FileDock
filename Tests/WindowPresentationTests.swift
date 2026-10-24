import AppKit

/// Window-level policy tests. These create deferred windows without ordering any
/// of them onscreen and never start an AppKit modal session or synthesize input.
@main
struct WindowPresentationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let browser = window(level: .floating)
        let bridge = window(level: .statusBar)
        let settings = window(level: .floating)
        let sheet = window(level: .floating)
        browser.addChildWindow(sheet, ordered: .above)
        // addChildWindow may inherit a level. Capture the actual pre-dialog value.
        let originalSheetLevel = sheet.level
        let dialog = window(level: .normal)
        let nestedDialog = window(level: .normal)
        let unrelated = window(level: .floating)
        HubWindowPresentation.backgroundWindows = { [browser, bridge, settings, browser] }
        var modalChanges: [Bool] = []
        HubWindowPresentation.modalStateDidChange = { modalChanges.append($0) }
        expect(!HubWindowPresentation.isPresentingDialog, "No dialog must be marked active initially")

        let response = HubWindowPresentation.withModalWindow(dialog) {
            expect(HubWindowPresentation.isPresentingDialog, "Presentation must suppress background activation before the operation starts")
            expect([browser, bridge, settings, sheet].allSatisfy { $0.level == .normal }, "All registered backgrounds and child sheets must sit below the picker")
            expect(dialog.level == .modalPanel, "The picker must be above normal and floating app content")
            expect(unrelated.level == .floating, "Unregistered windows must keep their own level")

            HubWindowPresentation.withModalWindow(nestedDialog) {
                expect(dialog.level == .normal && nestedDialog.level == .modalPanel, "Nested pickers must put the previous dialog behind the new one")
                expect(HubWindowPresentation.isPresentingDialog, "Nested presentation must remain active")
            }
            expect(dialog.level == .modalPanel && nestedDialog.level == .normal, "Closing a nested dialog must restore the previous dialog")
            expect(HubWindowPresentation.isPresentingDialog, "Returning from a nested operation must not end the outer modal scope")
            return 42
        }
        expect(response == 42, "The operation's result must pass through unchanged")
        expect(browser.level == .floating && bridge.level == .statusBar && settings.level == .floating,
               "Normal completion must restore every registered window's level")
        expect(sheet.level == originalSheetLevel && dialog.level == .normal, "Child and picker levels must restore after completion")
        expect(!HubWindowPresentation.isPresentingDialog, "Modal suppression must clear after the outermost operation")
        expect(modalChanges == [true, false], "Global shortcuts must suspend once and resume only after the outermost dialog")

        enum ExpectedError: Error { case cancelled }
        do {
            try HubWindowPresentation.withModalWindow(dialog) { throw ExpectedError.cancelled }
            preconditionFailure("A thrown operation must propagate its error")
        } catch ExpectedError.cancelled { }
        catch { preconditionFailure("Unexpected error: \(error)") }
        expect(browser.level == .floating && bridge.level == .statusBar && dialog.level == .normal,
               "Error unwinding must also restore levels")
        expect(!HubWindowPresentation.isPresentingDialog, "Error unwinding must clear background suppression")
        expect(modalChanges == [true, false, true, false], "Error unwinding must also restore shortcut registration")
        expect(HubWindowPresentation.auxiliaryLevel == .floating, "Settings must share the color panel's normal floating level")
        browser.level = HubWindowPresentation.browserLevel(embedded: true, auxiliaryVisible: false)
        expect(browser.level == .statusBar, "Embedded presentation must cover the menu bar beside the cutout")
        HubWindowPresentation.withModalWindow(dialog) {
            expect(browser.level == .normal && dialog.level == .modalPanel,
                   "Embedded presentation must yield to file pickers")
        }
        expect(browser.level == .statusBar, "Picker completion must restore the embedded presentation level")
        browser.level = HubWindowPresentation.browserLevel(embedded: true, auxiliaryVisible: true)
        expect(browser.level == settings.level, "Embedded browser must yield to settings window ordering")
        expect(HubWindowPresentation.previewLevel(browserLevel: .statusBar).rawValue > NSWindow.Level.statusBar.rawValue,
               "Quick Look must rise above embedded chrome without exposing the menu bar over its header")
        expect(HubWindowPresentation.previewLevel(browserLevel: .floating) == .floating,
               "Detached previews must retain ordinary floating ordering and yield to modal dialogs")
        expect(HubWindowPresentation.browserLevel(embedded: false, auxiliaryVisible: false) == .floating,
               "Connected and detached windows must retain their floating level")
        expect([browser, bridge, settings, sheet, dialog, nestedDialog, unrelated].allSatisfy { !$0.isVisible },
               "Policy tests must not display UI")
        HubWindowPresentation.backgroundWindows = nil
        HubWindowPresentation.modalStateDidChange = nil
        browser.removeChildWindow(sheet)
        print("PASS: modal ordering, registered child windows, nested restoration, error unwinding, auxiliary level and no visible test windows")
    }

    @MainActor private static func window(level: NSWindow.Level) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.level = level
        window.isReleasedWhenClosed = false
        return window
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
}
