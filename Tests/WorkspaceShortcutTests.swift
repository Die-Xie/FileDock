import AppKit
import SwiftUI

@main
struct WorkspaceShortcutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        for count in [0, 1, 9, 10, 99, 100, 99999] {
            for selected in [false, true] {
                let label = HubWorkspaceShortcutLabel(symbol: count == 0 ? "tray" : "tray.full.fill",
                                                      count: count, selected: selected)
                let unclipped = render(label.padding(8))
                let clipped = render(label.clipped().padding(8))
                precondition(unclipped.width == Int((HubWorkspaceShortcutLabel.width + 16) * 2) && unclipped.height == Int((HubWorkspaceShortcutLabel.height + 16) * 2))
                precondition(bytes(unclipped) == bytes(clipped),
                             "Clipping a measured shortcut must preserve every symbol/badge pixel (count \(count))")
                let pixels = bytes(unclipped)
                let row = unclipped.width * 4
                var visible = 0
                for y in 0..<unclipped.height {
                    for x in 0..<unclipped.width where pixels[y * row + x * 4 + 3] > 0 {
                        visible += 1
                        precondition(x >= 16 && x < Int((HubWorkspaceShortcutLabel.width + 8) * 2) && y >= 16 && y < Int((HubWorkspaceShortcutLabel.height + 8) * 2),
                                     "No pixels may overflow the reserved shortcut label")
                    }
                }
                precondition(visible > 30, "The snapshot must actually contain the rendered icon and count")
            }
        }
        print("PASS: rendered staging icons and 1/2/3-character badges fit their measured header bounds without clipping")
    }

    @MainActor private static func render<V: View>(_ view: V) -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.cgImage!
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }
}
