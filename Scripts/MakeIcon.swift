import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func gradient(_ path: CGPath, from: CGColor, to: CGColor, start: CGPoint, end: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [from, to] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
func fill(_ path: CGPath, _ color: CGColor) {
    context.addPath(path)
    context.setFillColor(color)
    context.fillPath()
}

let base = rounded(CGRect(x: 91, y: 91, width: 842, height: 842), 193)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: color(0, 0.10, 0.16, 0.45))
fill(base, color(0.03, 0.20, 0.27))
context.restoreGState()
gradient(base, from: color(0.15, 0.60, 0.71), to: color(0.018, 0.16, 0.24),
         start: CGPoint(x: 250, y: 913), end: CGPoint(x: 746, y: 105))
context.addPath(base)
context.setStrokeColor(color(0.8, 0.97, 1, 0.30))
context.setLineWidth(5)
context.strokePath()

let shell = rounded(CGRect(x: 243, y: 405, width: 538, height: 259), 67)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -17), blur: 28, color: color(0.01, 0.12, 0.22, 0.55))
fill(shell, color(0.5, 0.82, 0.86))
context.restoreGState()
gradient(shell, from: color(0.96, 0.99, 1), to: color(0.50, 0.80, 0.88),
         start: CGPoint(x: 512, y: 669), end: CGPoint(x: 512, y: 405))
fill(rounded(CGRect(x: 280, y: 439, width: 464, height: 85), 33), color(0.07, 0.24, 0.32))
fill(rounded(CGRect(x: 314, y: 473, width: 75, height: 16), 8), color(0.42, 0.61, 0.68))
fill(CGPath(ellipseIn: CGRect(x: 671, y: 470, width: 24, height: 24), transform: nil),
     color(0.42, 0.97, 0.73))

context.setLineWidth(31)
context.setLineCap(.round)
context.setStrokeColor(color(0.79, 0.97, 0.99))
context.addArc(center: CGPoint(x: 512, y: 316), radius: 80, startAngle: 3.36, endAngle: 5.93, clockwise: false)
context.strokePath()
context.addArc(center: CGPoint(x: 512, y: 316), radius: 80, startAngle: 0.22, endAngle: 2.81, clockwise: false)
context.strokePath()
for points in [[CGPoint(x: 603, y: 302), CGPoint(x: 589, y: 288), CGPoint(x: 568, y: 303)],
               [CGPoint(x: 419, y: 328), CGPoint(x: 436, y: 344), CGPoint(x: 457, y: 327)]] {
    context.move(to: points[0])
    context.addLine(to: points[1])
    context.addLine(to: points[2])
    context.setLineJoin(.round)
    context.strokePath()
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let dimensions = [16, 32, 64, 128, 256, 512, 1024]
let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.icns.identifier as CFString, dimensions.count, nil)!
let image = context.makeImage()!
for pixels in dimensions {
    let thumbnail = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    thumbnail.interpolationQuality = .high
    thumbnail.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    CGImageDestinationAddImage(writer, thumbnail.makeImage()!, nil)
}
guard CGImageDestinationFinalize(writer) else {
    throw CocoaError(.fileWriteUnknown)
}
