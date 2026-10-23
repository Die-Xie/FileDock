import AppKit

let destination = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let bounds = CGRect(x: 32, y: 32, width: 960, height: 960)
        let path = CGPath(roundedRect: bounds, cornerWidth: 218, cornerHeight: 218, transform: nil)
        context.addPath(path); context.clip()
        let colors = [NSColor(calibratedRed: 0.08, green: 0.30, blue: 0.39, alpha: 1).cgColor,
                      NSColor(calibratedRed: 0.10, green: 0.71, blue: 0.68, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 900, y: 1024), options: [])
        let panel = CGPath(roundedRect: CGRect(x: 174, y: 236, width: 676, height: 502), cornerWidth: 58, cornerHeight: 58, transform: nil)
        context.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        context.addPath(panel); context.fillPath()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor); context.setLineWidth(7)
        context.addPath(panel); context.strokePath()
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.80).cgColor)
        context.addPath(CGPath(roundedRect: CGRect(x: 354, y: 698, width: 316, height: 132), cornerWidth: 40, cornerHeight: 40, transform: nil)); context.fillPath()
        if let symbol = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 380, weight: .regular).applying(.init(paletteColors: [.white]))
            symbol.withSymbolConfiguration(config)?.draw(in: CGRect(x: 292, y: 302, width: 440, height: 352))
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
