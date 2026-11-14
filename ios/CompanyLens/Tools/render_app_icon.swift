import AppKit

// Run from the repository root with the destination PNG path as its argument.
// RGBX keeps the generated icon opaque while using a supported drawing context.
guard CommandLine.arguments.count == 2 else {
    print("Usage: swift render_app_icon.swift /path/to/AppIcon.png")
    exit(2)
}
let side = 1024
let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let font = NSFont(name: "Songti SC", size: 680) ?? NSFont.systemFont(ofSize: 680)
let attributes: [NSAttributedString.Key: Any] = [.font: font,
    .foregroundColor: NSColor(red: 0.965, green: 0.959, blue: 0.936, alpha: 1)]
let mark = "研" as NSString
let measured = mark.size(withAttributes: attributes)
mark.draw(at: NSPoint(x: (1024 - measured.width) / 2, y: (1024 - measured.height) / 2 + 18),
          withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: destination)
