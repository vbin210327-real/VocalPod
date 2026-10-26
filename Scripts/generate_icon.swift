import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Native artwork source. Run from the project root with Apple's Swift toolchain.
// The original 66/33 bar/gap proportions and 170/320/480 heights are preserved.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let size = 1024
let scale: CGFloat = 1.6
let center = CGFloat(size) / 2
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func gray(_ value: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [value, value, value, 1])!
}

let background = CGGradient(colorsSpace: colorSpace,
                            colors: [gray(26 / 255), gray(20 / 255)] as CFArray,
                            locations: [0, 1])!
context.drawRadialGradient(background,
                           startCenter: CGPoint(x: center, y: center + 48), startRadius: 0,
                           endCenter: CGPoint(x: center, y: center + 48), endRadius: 760,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

let silver = CGGradient(colorsSpace: colorSpace,
                        colors: [gray(218 / 255), gray(184 / 255)] as CFArray,
                        locations: [0, 1])!
let width: CGFloat = 66 * scale
let pitch: CGFloat = 99 * scale
for (index, height) in [170.0, 320, 480, 320, 170].enumerated() {
    let height = CGFloat(height) * scale
    let rect = CGRect(x: center + CGFloat(index - 2) * pitch - width / 2,
                      y: center - height / 2, width: width, height: height)
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    context.clip()
    context.drawLinearGradient(silver,
                               start: CGPoint(x: center, y: center + 240 * scale),
                               end: CGPoint(x: center, y: center - 240 * scale),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

let image = context.makeImage()!
for path in ["VocalPod/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
             "VocalPod/Assets.xcassets/PodIcon.imageset/PodIcon.png"] {
    let url = root.appendingPathComponent(path)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "Unable to write icon")
}
print("Generated matching opaque 1024px icons: 72.2% mark width, 75% mark height.")
