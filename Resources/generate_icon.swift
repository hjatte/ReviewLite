import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false, drawingHandler: { rect in
    let cornerRadius: CGFloat = 224
    let clip = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    clip.addClip()

    // Solid black background with a very faint top highlight for depth.
    let bg = NSGradient(colors: [
        NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1.0)
    ])!
    bg.draw(in: rect, angle: 270)

    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.05),
        NSColor.white.withAlphaComponent(0.0)
    ])!
    highlight.draw(in: NSRect(x: 0, y: size * 0.55, width: size, height: size * 0.45), angle: 90)

    // Classic ⏪ rewind: two left-pointing triangles, centred.
    let triW: CGFloat = 290
    let triH: CGFloat = 360
    let gap: CGFloat = 36
    let totalW = triW * 2 + gap
    let startX = (size - totalW) / 2
    let cy = size / 2

    // Yellow rewind triangles.
    NSColor(srgbRed: 1.0, green: 0.82, blue: 0.10, alpha: 1.0).setFill()
    for i in 0..<2 {
        let x = startX + CGFloat(i) * (triW + gap)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x + triW, y: cy + triH / 2))
        p.line(to: NSPoint(x: x,         y: cy))
        p.line(to: NSPoint(x: x + triW, y: cy - triH / 2))
        p.close()
        p.fill()
    }

    return true
})

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png encode failed")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok: \(CommandLine.arguments[1])")
