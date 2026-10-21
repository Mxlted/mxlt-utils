import AppKit
import Foundation

// Original geometric mxlt mark: two rising strokes and a small utility accent.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ pixels: Int, _ filename: String) throws {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let body = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 206, yRadius: 206)
    NSColor(calibratedRed: 0.08, green: 0.12, blue: 0.17, alpha: 1).setFill(); body.fill()
    let stroke = NSBezierPath()
    stroke.move(to: NSPoint(x: 250, y: 325)); stroke.line(to: NSPoint(x: 250, y: 665))
    stroke.line(to: NSPoint(x: 510, y: 425)); stroke.line(to: NSPoint(x: 770, y: 665))
    stroke.line(to: NSPoint(x: 770, y: 325))
    stroke.lineWidth = 94; stroke.lineJoinStyle = .round; stroke.lineCapStyle = .round
    NSColor(calibratedRed: 0.45, green: 0.92, blue: 0.79, alpha: 1).setStroke(); stroke.stroke()
    NSColor(calibratedRed: 0.96, green: 0.73, blue: 0.36, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 466, y: 225, width: 88, height: 88)).fill()
    image.unlockFocus()
    guard let tiff=image.tiffRepresentation, let rep=NSBitmapImageRep(data:tiff), let png=rep.representation(using:.png, properties:[:]) else { fatalError("PNG encoding failed") }
    try png.write(to: output.appendingPathComponent(filename))
}
for size in [16,32,128,256,512] {
    try render(size,"icon_\(size)x\(size).png")
    try render(size*2,"icon_\(size)x\(size)@2x.png")
}
