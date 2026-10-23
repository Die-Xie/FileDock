import Foundation
import CoreGraphics

@main
struct NotchGeometryTests {
    private static func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        precondition(abs(actual - expected) < 0.001, "\(message): \(actual) != \(expected)")
    }

    private static func checkPlacement(_ placement: HubNotchPlacement, screen: CGRect, visible: CGRect, top: CGFloat) {
        let body = placement.bodyFrame, bridge = placement.bridgeFrame
        precondition(body.width > 0 && body.height > 0, "Body must have positive dimensions")
        precondition(body.minX >= visible.minX && body.maxX <= visible.maxX, "Body must fit the usable horizontal area")
        precondition(body.minY >= visible.minY + 11.999, "Body must leave the lower screen margin")
        near(body.maxY, top - HubNotchMotion.neckDepth, "Body must leave room for the flexible neck below the inset")
        near(bridge.midX, screen.midX, "Connector must center on the selected display")
        near(bridge.minX, body.minX, "Wide connector and body must share a coordinate space")
        near(bridge.width, body.width, "Connection must span toward both body corners")
        near(bridge.maxY, screen.maxY, "Connector must reach the physical top edge")
        near(bridge.minY, body.maxY - 1, "Separate surfaces must overlap by one point")
        precondition(bridge.intersection(body).height >= 0.999, "Connector/body cannot expose a compositing seam")
        precondition(placement.sourceWidth >= 100 && placement.sourceWidth <= body.width - 100, "Stem must fit within the body shoulders")
    }

    static func main() {
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let builtInVisible = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let notch = HubNotchPlacement.make(screenFrame: builtIn, visibleFrame: builtInVisible, safeTop: 38,
                                           leftAuxiliary: CGRect(x: 0, y: 944, width: 650, height: 38),
                                           rightAuxiliary: CGRect(x: 862, y: 944, width: 650, height: 38),
                                           requestedSize: CGSize(width: 900, height: 480))
        checkPlacement(notch, screen: builtIn, visible: builtInVisible, top: 944)
        near(notch.sourceWidth, 212, "Hardware width must come from auxiliary areas")
        near(notch.bodyFrame.midX, builtIn.midX, "Body must be centered")
        near(notch.bodyFrame.height, 480, "Requested content height must exclude the connector")
        let connection = HubNotchMotion.neckPath(in: CGRect(origin: .zero, size: notch.bridgeFrame.size),
                                                sourceWidth: notch.sourceWidth, state: .open).boundingBoxOfPath
        near(connection.minX, HubNotchMotion.cornerInset, "The wide curve must flatten before the left body corner")
        near(connection.maxX, notch.bodyFrame.width - HubNotchMotion.cornerInset, "The wide curve must flatten before the right body corner")

        let secondary = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let secondaryVisible = CGRect(x: -1920, y: 120, width: 1920, height: 1056)
        let offset = HubNotchPlacement.make(screenFrame: secondary, visibleFrame: secondaryVisible, safeTop: 0,
                                            leftAuxiliary: nil, rightAuxiliary: nil,
                                            requestedSize: CGSize(width: 1000, height: 640))
        checkPlacement(offset, screen: secondary, visible: secondaryVisible, top: 1176)
        near(offset.sourceWidth, 186, "Non-notched displays use the virtual stem width")
        near(offset.bodyFrame.midX, -960, "Negative screen origins must not be treated as primary-screen coordinates")

        let lower = CGRect(x: 2500, y: -1100, width: 1280, height: 800)
        let lowerVisible = CGRect(x: 2500, y: -1060, width: 1280, height: 738)
        let lowerPlacement = HubNotchPlacement.make(screenFrame: lower, visibleFrame: lowerVisible, safeTop: 0,
                                                   leftAuxiliary: nil, rightAuxiliary: nil,
                                                   requestedSize: CGSize(width: 700, height: 400))
        checkPlacement(lowerPlacement, screen: lower, visible: lowerVisible, top: -322)
        near(lowerPlacement.bodyFrame.midX, 3140, "Positive X and negative Y display offsets must be retained")

        let full = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let hiddenMenu = HubNotchPlacement.make(screenFrame: full, visibleFrame: full, safeTop: 32,
                                               leftAuxiliary: nil, rightAuxiliary: nil,
                                               requestedSize: CGSize(width: 900, height: 500))
        checkPlacement(hiddenMenu, screen: full, visible: full, top: 868)
        near(hiddenMenu.bridgeFrame.height, 33 + HubNotchMotion.neckDepth, "A hidden menu bar must still reserve the hardware safe area and neck")

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let large = HubNotchPlacement.make(screenFrame: full, visibleFrame: visible, safeTop: 0,
                                           leftAuxiliary: nil, rightAuxiliary: nil,
                                           requestedSize: CGSize(width: 20_000, height: 20_000))
        checkPlacement(large, screen: full, visible: visible, top: 875)
        near(large.bodyFrame.width, 1416, "Oversized widths must fit with horizontal margins")
        near(large.bodyFrame.height, 863 - HubNotchMotion.neckDepth, "Oversized heights must fit below the menu bar and neck")

        let flatFullscreen = HubNotchPlacement.make(screenFrame: full, visibleFrame: full, safeTop: 0,
                                                    leftAuxiliary: nil, rightAuxiliary: nil,
                                                    requestedSize: CGSize(width: 900, height: 500))
        checkPlacement(flatFullscreen, screen: full, visible: full, top: 890)
        near(flatFullscreen.bridgeFrame.height, 11 + HubNotchMotion.neckDepth, "Unnotched fullscreen displays retain a flexible edge attachment")

        let compact = CGRect(x: 0, y: 0, width: 640, height: 480)
        let compactVisible = CGRect(x: 0, y: 0, width: 640, height: 458)
        let minimum = HubNotchPlacement.make(screenFrame: compact, visibleFrame: compactVisible, safeTop: 0,
                                             leftAuxiliary: nil, rightAuxiliary: nil,
                                             requestedSize: CGSize(width: 100, height: 100))
        checkPlacement(minimum, screen: compact, visible: compactVisible, top: 458)
        near(minimum.bodyFrame.width, 600, "Usable compact screens must retain minimum content width")
        near(minimum.bodyFrame.height, 300, "Usable compact screens must retain minimum content height")

        let broadNotch = HubNotchPlacement.make(screenFrame: full, visibleFrame: visible, safeTop: 25,
                                                leftAuxiliary: CGRect(x: 0, y: 875, width: 200, height: 25),
                                                rightAuxiliary: CGRect(x: 1240, y: 875, width: 200, height: 25),
                                                requestedSize: CGSize(width: 600, height: 400))
        checkPlacement(broadNotch, screen: full, visible: visible, top: 875)
        near(broadNotch.sourceWidth, 500, "Unusually wide reported cutouts must preserve body shoulders")

        for dockOnLeft in [true, false] {
            let sideDockVisible = CGRect(x: dockOnLeft ? 90 : 0, y: 0, width: 1350, height: 875)
            let sideDock = HubNotchPlacement.make(screenFrame: full, visibleFrame: sideDockVisible, safeTop: 25,
                                                  leftAuxiliary: nil, rightAuxiliary: nil,
                                                  requestedSize: CGSize(width: 20_000, height: 500))
            checkPlacement(sideDock, screen: full, visible: sideDockVisible, top: 875)
            near(sideDock.bodyFrame.midX, full.midX, "A side Dock must not pull the panel and stem away from the hardware center")
            near(sideDock.bodyFrame.width, 1236, "A side Dock must limit the panel by the smaller available shoulder")
        }

        testEmbeddedPlacement()
        print("PASS: notch auxiliary width, multi-display offsets, menu/safe-area anchors, fullscreen fallback, size bounds, connector overlap and embedded-header safe regions")
    }

    private static func testEmbeddedPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 48, width: 1512, height: 896)
        let left = CGRect(x: 0, y: 944, width: 650, height: 38)
        let right = CGRect(x: 862, y: 944, width: 650, height: 38)
        let embedded = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: visible, safeTop: 38,
                                                 leftAuxiliary: left, rightAuxiliary: right,
                                                 requestedSize: CGSize(width: 900, height: 480))
        checkEmbedded(embedded, screen: screen, visible: visible)
        near(embedded.bodyFrame.height, 480, "Embedded panels retain their requested total height")
        near(embedded.sourceWidth, 212, "Embedded reveal must originate at the measured hardware width")
        near(embedded.topInset, 38, "Header cutout depth must use the safe top inset")
        near(embedded.headerExclusionWidth, 236, "Header must leave clearance on both sides of the cutout")
        precondition(embedded.usesSplitHeader, "A wide panel must place controls beside the actual cutout")

        let compact = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: visible, safeTop: 38,
                                                leftAuxiliary: left, rightAuxiliary: right,
                                                requestedSize: CGSize(width: 600, height: 300))
        checkEmbedded(compact, screen: screen, visible: visible)
        precondition(!compact.usesSplitHeader, "A narrow panel must move its complete toolbar below the cutout")
        near(compact.topInset, 38, "Narrow fallback must still protect the cutout depth")

        let hiddenMenu = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: screen, safeTop: 38,
                                                   leftAuxiliary: left, rightAuxiliary: right,
                                                   requestedSize: CGSize(width: 900, height: 480))
        near(hiddenMenu.topInset, 38, "Hiding the menu bar must not remove hardware protection")
        precondition(hiddenMenu.usesSplitHeader)

        let missingAuxiliary = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: screen, safeTop: 38,
                                                        leftAuxiliary: nil, rightAuxiliary: nil,
                                                        requestedSize: CGSize(width: 900, height: 480))
        near(missingAuxiliary.topInset, 38,
             "A hidden menu bar and missing auxiliary regions must retain the hardware safe inset")
        precondition(!missingAuxiliary.usesSplitHeader && missingAuxiliary.headerExclusionWidth == 0,
                     "Without measured cutout width, the full toolbar must sit below the safe inset")

        let invalidAuxiliary = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: screen, safeTop: 38,
                                                        leftAuxiliary: left,
                                                        rightAuxiliary: CGRect(x: 660, y: 944, width: 852, height: 38),
                                                        requestedSize: CGSize(width: 900, height: 480))
        near(invalidAuxiliary.topInset, 38,
             "An unusable auxiliary gap must not discard the known hardware safe inset")
        precondition(!invalidAuxiliary.usesSplitHeader)

        for (safeTop, auxLeft, auxRight) in [(CGFloat(0), Optional(left), Optional(right)),
                                            (CGFloat(38), nil, nil),
                                            (CGFloat(38), Optional(left), Optional(CGRect(x: 660, y: 944, width: 852, height: 38)))] {
            let fallback = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: visible, safeTop: safeTop,
                                                     leftAuxiliary: auxLeft, rightAuxiliary: auxRight,
                                                     requestedSize: CGSize(width: 900, height: 480))
            precondition(!fallback.usesSplitHeader && fallback.headerExclusionWidth == 0,
                         "A safe top or auxiliary gap alone cannot establish a real cutout")
            near(fallback.topInset, 38, "Unestablished cutouts use the visible menu inset")
        }

        let hugeNotch = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: visible, safeTop: 38,
                                                 leftAuxiliary: CGRect(x: 0, y: 944, width: 100, height: 38),
                                                 rightAuxiliary: CGRect(x: 1412, y: 944, width: 100, height: 38),
                                                 requestedSize: CGSize(width: 600, height: 300))
        near(hugeNotch.headerExclusionWidth, 576, "Unusually wide cutouts must clamp the header reservation to panel width")
        precondition(!hugeNotch.usesSplitHeader)

        let secondary = CGRect(x: -1920, y: 120, width: 1920, height: 1080)
        let secondaryVisible = CGRect(x: -1920, y: 160, width: 1920, height: 1016)
        let plain = HubEmbeddedPlacement.make(screenFrame: secondary, visibleFrame: secondaryVisible, safeTop: 0,
                                              leftAuxiliary: nil, rightAuxiliary: nil,
                                              requestedSize: CGSize(width: 1000, height: 640))
        checkEmbedded(plain, screen: secondary, visible: secondaryVisible)
        near(plain.bodyFrame.maxY, 1200, "Secondary display origins must be retained at the top")
        near(plain.sourceWidth, 186, "Unnotched displays use a virtual source for reveal")
        near(plain.topInset, 24, "Unnotched displays reserve their menu inset")
        precondition(!plain.usesSplitHeader && plain.headerExclusionWidth == 0)

        let lower = CGRect(x: 2500, y: -1100, width: 1280, height: 800)
        let lowerVisible = CGRect(x: 2500, y: -1060, width: 1280, height: 738)
        let lowerPlacement = HubEmbeddedPlacement.make(screenFrame: lower, visibleFrame: lowerVisible, safeTop: 0,
                                                       leftAuxiliary: nil, rightAuxiliary: nil,
                                                       requestedSize: CGSize(width: 20_000, height: 20_000))
        checkEmbedded(lowerPlacement, screen: lower, visible: lowerVisible)
        near(lowerPlacement.bodyFrame.width, 1256, "Oversized embedded widths retain horizontal margins")
        near(lowerPlacement.bodyFrame.height, 748, "Embedded height uses the physical top rather than the menu bottom")

        for dockOnLeft in [true, false] {
            let dockVisible = CGRect(x: dockOnLeft ? 90 : 0, y: 48, width: 1422, height: 896)
            let placement = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: dockVisible, safeTop: 38,
                                                      leftAuxiliary: left, rightAuxiliary: right,
                                                      requestedSize: CGSize(width: 20_000, height: 20_000))
            checkEmbedded(placement, screen: screen, visible: dockVisible)
            near(placement.bodyFrame.width, 1308, "A side Dock limits both shoulders by the smaller safe side")
        }

        let fullscreen = HubEmbeddedPlacement.make(screenFrame: screen, visibleFrame: screen, safeTop: 0,
                                                   leftAuxiliary: nil, rightAuxiliary: nil,
                                                   requestedSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity))
        checkEmbedded(fullscreen, screen: screen, visible: screen)
        near(fullscreen.bodyFrame.width, 900, "Non-finite requested width uses the default")
        near(fullscreen.bodyFrame.height, 480, "Non-finite requested height uses the default")
        near(fullscreen.topInset, 0, "Unnotched fullscreen has no artificial top inset")
    }

    private static func checkEmbedded(_ placement: HubEmbeddedPlacement, screen: CGRect, visible: CGRect) {
        near(placement.bodyFrame.maxY, screen.maxY, "Embedded panel must meet the physical screen top")
        near(placement.bodyFrame.midX, screen.midX, "Embedded panel must stay centered on the hardware cutout")
        precondition(placement.bodyFrame.minX >= visible.minX + 11.999 && placement.bodyFrame.maxX <= visible.maxX - 11.999,
                     "Embedded panel must fit horizontal visible margins")
        precondition(placement.bodyFrame.minY >= visible.minY + 11.999,
                     "Embedded panel must stay above the visible bottom margin")
        precondition(placement.bodyFrame.width > 0 && placement.bodyFrame.height > 0)
    }
}
