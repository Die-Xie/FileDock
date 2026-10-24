import SwiftUI

/// The badge belongs to the measured label, rather than overflowing a smaller
/// symbol frame that the embedded header's viewport would clip.
struct HubWorkspaceShortcutLabel: View {
    static let width: CGFloat = 30
    static let height: CGFloat = 32

    let symbol: String
    var count = 0
    var selected = false
    var targeted = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: Self.width, height: Self.height)
                .foregroundStyle(selected || targeted ? Color.accentColor : Color.secondary)
            if count > 0 {
                Text(count > 99 ? "99+" : String(count))
                    .font(.system(size: 8, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 12)
                    .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    .padding(.top, 1).padding(.trailing, 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background(targeted ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
