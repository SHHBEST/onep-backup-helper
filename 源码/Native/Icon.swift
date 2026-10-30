import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let space = CGColorSpaceCreateDeviceRGB()
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func round(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func gradient(_ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path); context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}
let base = round(CGRect(x: 52, y: 52, width: 920, height: 920), 214)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -13), blur: 25, color: color(0.02, 0.16, 0.23, 0.23))
context.addPath(base); context.setFillColor(color(0.1, 0.55, 0.64)); context.fillPath()
context.restoreGState()
gradient(base, [color(0.65, 0.93, 0.97), color(0.20, 0.67, 0.77), color(0.03, 0.31, 0.45)],
         from: CGPoint(x: 130, y: 1010), to: CGPoint(x: 830, y: 30))
context.addPath(base); context.setStrokeColor(color(1, 1, 1, 0.6)); context.setLineWidth(3); context.strokePath()
for (angle, offset, alpha) in [(-0.19, -48.0, 0.25), (0.16, 48.0, 0.48)] {
    context.saveGState()
    context.translateBy(x: 512 + offset, y: 512)
    context.rotate(by: angle)
    let back = round(CGRect(x: -229, y: -272, width: 458, height: 544), 106)
    gradient(back, [color(1, 1, 1, alpha), color(0.75, 0.97, 1, alpha * 0.3)],
             from: CGPoint(x: -200, y: 270), to: CGPoint(x: 200, y: -270))
    context.addPath(back); context.setStrokeColor(color(1, 1, 1, 0.55)); context.setLineWidth(2); context.strokePath()
    context.restoreGState()
}
let door = round(CGRect(x: 280, y: 234, width: 464, height: 556), 110)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -25), blur: 37, color: color(0.01, 0.24, 0.35, 0.25))
context.addPath(door); context.setFillColor(color(0.80, 0.96, 0.99, 0.8)); context.fillPath()
context.restoreGState()
gradient(door, [color(1, 1, 1, 0.75), color(0.84, 0.99, 1, 0.20)],
         from: CGPoint(x: 300, y: 790), to: CGPoint(x: 700, y: 230))
context.addPath(door); context.setLineWidth(4); context.setStrokeColor(color(1, 1, 1, 0.8)); context.strokePath()
context.setFillColor(color(1, 1, 1, 0.14))
context.fillEllipse(in: CGRect(x: 361, y: 362, width: 302, height: 302))
context.setLineWidth(3); context.setStrokeColor(color(0.05, 0.39, 0.49, 0.28))
context.strokeEllipse(in: CGRect(x: 361, y: 362, width: 302, height: 302))
context.setFillColor(color(0.03, 0.39, 0.49))
context.fillEllipse(in: CGRect(x: 472, y: 492, width: 80, height: 80))
context.addPath(round(CGRect(x: 490, y: 431, width: 44, height: 102), 18)); context.fillPath()
for y in [366, 588] {
    context.addPath(round(CGRect(x: 271, y: y, width: 22, height: 76), 9))
    context.setFillColor(color(1, 1, 1, 0.90)); context.fillPath()
}
let image = context.makeImage()!
for (size, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                       (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                       (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let scaled = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    scaled.interpolationQuality = .high
    scaled.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let file = destination.appendingPathComponent("icon_\(suffix).png")
    let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, scaled.makeImage()!, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not write icon") }
}
