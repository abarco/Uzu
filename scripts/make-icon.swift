import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Uzu app icon: three arrows converging into one, flowing right → left.
// 1024×1024, crimson gradient background, white strokes.

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: deep crimson gradient, top-left light → bottom-right dark.
let bgColors = [
    CGColor(red: 0.91, green: 0.22, blue: 0.33, alpha: 1),  // #E83854
    CGColor(red: 0.55, green: 0.06, blue: 0.19, alpha: 1),  // #8C0F30
] as CFArray
let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(size)),
    end: CGPoint(x: CGFloat(size), y: 0),
    options: [])

// Subtle vortex hint: faint concentric circle behind the arrows (Uzu = whirlpool).
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
context.setLineWidth(56)
context.strokeEllipse(in: CGRect(x: 132, y: 132, width: 760, height: 760))

let midY: CGFloat = 512
let mergeX: CGFloat = 470
let sourceX: CGFloat = 880
let spread: CGFloat = 246

func strokeArrowPath(_ build: (CGMutablePath) -> Void, width: CGFloat, alpha: CGFloat) {
    let path = CGMutablePath()
    build(path)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(path)
    context.strokePath()
}

// Top tributary: starts upper right, curves into the merge point.
strokeArrowPath({ path in
    path.move(to: CGPoint(x: sourceX, y: midY + spread))
    path.addCurve(
        to: CGPoint(x: mergeX, y: midY),
        control1: CGPoint(x: 660, y: midY + spread),
        control2: CGPoint(x: 620, y: midY))
}, width: 62, alpha: 0.82)

// Bottom tributary: mirror image.
strokeArrowPath({ path in
    path.move(to: CGPoint(x: sourceX, y: midY - spread))
    path.addCurve(
        to: CGPoint(x: mergeX, y: midY),
        control1: CGPoint(x: 660, y: midY - spread),
        control2: CGPoint(x: 620, y: midY))
}, width: 62, alpha: 0.82)

// Middle tributary: straight shot into the merge.
strokeArrowPath({ path in
    path.move(to: CGPoint(x: sourceX, y: midY))
    path.addLine(to: CGPoint(x: mergeX + 10, y: midY))
}, width: 62, alpha: 0.92)

// Merged single arrow: thicker shaft continuing left...
strokeArrowPath({ path in
    path.move(to: CGPoint(x: mergeX, y: midY))
    path.addLine(to: CGPoint(x: 268, y: midY))
}, width: 92, alpha: 1.0)

// ...ending in a solid arrowhead.
let head = CGMutablePath()
head.move(to: CGPoint(x: 148, y: midY))
head.addLine(to: CGPoint(x: 320, y: midY + 128))
head.addLine(to: CGPoint(x: 320, y: midY - 128))
head.closeSubpath()
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.addPath(head)
context.fillPath()

// Write PNG.
let image = context.makeImage()!
let outputURL = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "AppIcon.png")
let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(outputURL.path)")
