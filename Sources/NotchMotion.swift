import Foundation
import CoreGraphics

/// Shared geometry and timing for the body and its click-through liquid neck.
/// The body top sits `neckDepth` below the hardware/menu-bar inset; the bridge
/// spans from the screen's top through that gap and overlaps the body by 1 pt.
enum HubNotchMotion {
    static let neckDepth: CGFloat = 26
    /// The connection joins the body's flat top before its rounded corners.
    static let cornerInset: CGFloat = 32
    static let openingDuration: TimeInterval = 0.30
    static let closingDuration: TimeInterval = 0.22
    static let bodyOpeningLead: TimeInterval = 0.034
    static let bodyClosingDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.10
    // The native extension canvas reserves room for one real size overshoot.
    static let extensionOpeningDuration: TimeInterval = 0.38
    static let extensionArrivalFraction: Double = (3 + sqrt(36.2)) / 13.6
    static let extensionSettlingDuration: TimeInterval = 0.12
    static let extensionSampleCount = 91
    static let extensionSideOverscan: CGFloat = 10
    static let extensionBottomOverscan: CGFloat = 12

    static func extensionWindowFrame(for restingFrame: CGRect, enabled: Bool) -> CGRect {
        guard validRectangle(restingFrame) else { return .zero }
        guard enabled else { return restingFrame }
        return CGRect(x: restingFrame.minX - extensionSideOverscan,
                      y: restingFrame.minY - extensionBottomOverscan,
                      width: restingFrame.width + 2 * extensionSideOverscan,
                      height: restingFrame.height + extensionBottomOverscan)
    }

    static func extensionRestingBounds(in bounds: CGRect, enabled: Bool) -> CGRect {
        guard validRectangle(bounds) else { return .zero }
        guard enabled else { return bounds }
        let side = min(extensionSideOverscan, bounds.width / 2)
        let bottom = min(extensionBottomOverscan, bounds.height)
        return CGRect(x: bounds.minX + side, y: bounds.minY + bottom,
                      width: bounds.width - 2 * side, height: bounds.height - bottom)
    }

    private static func validRectangle(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite &&
            rect.width.isFinite && rect.height.isFinite && rect.width >= 0 && rect.height >= 0
    }

    static func extensionProgress(at progress: Double) -> CGFloat {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        // A single polynomial starts at zero velocity, passes the target once,
        // and returns monotonically from its only peak. Velocity and
        // acceleration reach zero at rest, without splicing two tail easings.
        return CGFloat(1 - pow(1 - t, 3) * (1 + 3 * t - 6.8 * t * t))
    }

    static func normalizedSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(2, max(0.5, speed)) : 1
    }

    static func scaledDuration(_ duration: TimeInterval, speed: Double) -> TimeInterval {
        duration / normalizedSpeed(speed)
    }

    static func stemWidth(in bounds: CGRect, sourceWidth: CGFloat) -> CGFloat {
        min(max(20, sourceWidth.isFinite ? sourceWidth : 200), max(0, bounds.width - 4))
    }

    static func connectionFlare(in bounds: CGRect, sourceWidth: CGFloat) -> CGFloat {
        max(0, (bounds.width - stemWidth(in: bounds, sourceWidth: sourceWidth)) / 2 - cornerInset)
    }

    struct NeckState {
        var extent: CGFloat
        var shoulder: CGFloat
        static let closed = NeckState(extent: 0, shoulder: 0)
        static let open = NeckState(extent: 1, shoulder: 1)
    }

    /// Every state has identical path commands, so the GPU interpolates a
    /// continuous silhouette even when an animation reverses part way through.
    static func neckPath(in bounds: CGRect, sourceWidth: CGFloat, state: NeckState) -> CGPath {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return CGMutablePath() }
        let width = stemWidth(in: bounds, sourceWidth: sourceWidth)
        let extent = min(1, max(0, state.extent.isFinite ? state.extent : 0))
        let depth = min(neckDepth, bounds.height)
        let lipY = bounds.minY + depth
        let bottomY = lipY - depth * extent
        let length = lipY - bottomY
        let half = width / 2
        let shoulderScale = state.shoulder.isFinite ? state.shoulder : 0
        let flare = connectionFlare(in: bounds, sourceWidth: sourceWidth) * max(0, min(1, shoulderScale)) * extent
        let shoulder = half + flare
        let center = bounds.midX
        let p = CGMutablePath()
        p.move(to: CGPoint(x: center - half, y: bounds.maxY))
        p.addLine(to: CGPoint(x: center + half, y: bounds.maxY))
        p.addLine(to: CGPoint(x: center + half, y: lipY))
        // One curve per side: vertical at the hub, horizontal at the body.
        // There is no middle waist node/tangent to create a step or bulge.
        p.addCurve(to: CGPoint(x: center + shoulder, y: bottomY),
                   control1: CGPoint(x: center + half, y: lipY - length * 0.55),
                   control2: CGPoint(x: center + half + flare * 0.35, y: bottomY))
        p.addLine(to: CGPoint(x: center - shoulder, y: bottomY))
        p.addCurve(to: CGPoint(x: center - half, y: lipY),
                   control1: CGPoint(x: center - half - flare * 0.35, y: bottomY),
                   control2: CGPoint(x: center - half, y: lipY - length * 0.55))
        p.addLine(to: CGPoint(x: center - half, y: bounds.maxY))
        p.closeSubpath()
        return p
    }
}
