import Foundation

/// A real player observation, advanced locally for at most one short polling gap.
/// Monotonic time avoids jumping when the system clock changes.
struct HubMusicProgress: Sendable, Equatable {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let rate: Double
    let sampledAt: TimeInterval
    static let maximumExtrapolation: TimeInterval = 5

    init?(elapsed: TimeInterval, duration: TimeInterval, rate: Double,
          sampledAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard elapsed.isFinite, duration.isFinite, rate.isFinite, sampledAt.isFinite,
              elapsed >= 0, duration > 0, duration <= 604_800, elapsed <= duration + 2,
              (0...4).contains(rate) else { return nil }
        self.elapsed = min(duration, elapsed); self.duration = duration
        self.rate = rate; self.sampledAt = sampledAt
    }
    func position(at now: TimeInterval) -> TimeInterval {
        let age = now.isFinite ? min(Self.maximumExtrapolation, max(0, now - sampledAt)) : 0
        return min(duration, elapsed + age * rate)
    }
    func fraction(at now: TimeInterval) -> Double { position(at: now) / duration }
    func matches(_ other: Self) -> Bool {
        elapsed == other.elapsed && duration == other.duration && rate == other.rate &&
            (rate == 0 || sampledAt == other.sampledAt)
    }
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "—:—" }
        let value = Int(min(604_800, max(0, seconds)))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
    var description: String {
        "\(Self.clock(position(at: ProcessInfo.processInfo.systemUptime))) / \(Self.clock(duration))"
    }
}
