import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Vitruvian Man, after Leonardo: square side = height = arm span; circle centred on the navel,
// its bottom on the square's base. Two superimposed poses.
struct Style { let background: [CGColor]; let ink: CGColor; let figure: CGColor }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ style: Style, to path: String) {
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // y-down coordinates.
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

    // Background: radial "parchment" gradient (or flat for single-colour styles).
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: style.background as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 760, options: [.drawsAfterEndLocation])

    let height: CGFloat = 640                 // the man's height = square side
    let top: CGFloat = 256                    // top of head / top of square
    let bottom = top + height                 // feet / base of square
    let left: CGFloat = 512 - height / 2, right: CGFloat = 512 + height / 2
    let navel = CGPoint(x: 512, y: bottom - height * 0.6)
    let radius = bottom - navel.y             // circle touches the base

    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    // Square and circle: thin ink lines.
    ctx.setStrokeColor(style.ink); ctx.setLineWidth(9)
    ctx.stroke(CGRect(x: left, y: top, width: height, height: height))
    ctx.strokeEllipse(in: CGRect(x: navel.x - radius, y: navel.y - radius, width: radius * 2, height: radius * 2))

    // Figure: a filled ink silhouette, so it reads at small sizes.
    ctx.setFillColor(style.figure)
    let headCenter = CGPoint(x: 512, y: top + 46)
    let shoulderY = top + height * 0.2
    let shoulderL = CGPoint(x: 512 - 62, y: shoulderY + 6), shoulderR = CGPoint(x: 512 + 62, y: shoulderY + 6)
    let pelvisY = top + height * 0.53
    let hipL = CGPoint(x: 512 - 34, y: pelvisY), hipR = CGPoint(x: 512 + 34, y: pelvisY)

    func onCircle(_ degrees: CGFloat) -> CGPoint {  // 0° = right, 90° = down
        let a = degrees * .pi / 180
        return CGPoint(x: navel.x + radius * cos(a), y: navel.y + radius * sin(a))
    }
    // A limb tapering from width w1 at `a` to w2 at `b`, with rounded ends.
    func limb(_ a: CGPoint, _ b: CGPoint, _ w1: CGFloat, _ w2: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y, length = (dx * dx + dy * dy).squareRoot()
        let nx = -dy / length, ny = dx / length
        ctx.beginPath()
        ctx.move(to: CGPoint(x: a.x + nx * w1 / 2, y: a.y + ny * w1 / 2))
        ctx.addLine(to: CGPoint(x: b.x + nx * w2 / 2, y: b.y + ny * w2 / 2))
        ctx.addLine(to: CGPoint(x: b.x - nx * w2 / 2, y: b.y - ny * w2 / 2))
        ctx.addLine(to: CGPoint(x: a.x - nx * w1 / 2, y: a.y - ny * w1 / 2))
        ctx.closePath(); ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: a.x - w1 / 2, y: a.y - w1 / 2, width: w1, height: w1))
        ctx.fillEllipse(in: CGRect(x: b.x - w2 / 2, y: b.y - w2 / 2, width: w2, height: w2))
    }

    // Head and neck.
    ctx.fillEllipse(in: CGRect(x: headCenter.x - 36, y: headCenter.y - 44, width: 72, height: 88))
    ctx.fill(CGRect(x: 512 - 15, y: headCenter.y + 30, width: 30, height: shoulderY - headCenter.y - 20))

    // Torso: broad shoulders, narrower waist, hips.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 512 - 74, y: shoulderY))
    ctx.addLine(to: CGPoint(x: 512 + 74, y: shoulderY))
    ctx.addQuadCurve(to: CGPoint(x: 512 + 40, y: top + height * 0.42), control: CGPoint(x: 512 + 62, y: top + height * 0.32))
    ctx.addLine(to: CGPoint(x: 512 + 50, y: pelvisY + 12))
    ctx.addLine(to: CGPoint(x: 512 - 50, y: pelvisY + 12))
    ctx.addLine(to: CGPoint(x: 512 - 40, y: top + height * 0.42))
    ctx.addQuadCurve(to: CGPoint(x: 512 - 74, y: shoulderY), control: CGPoint(x: 512 - 62, y: top + height * 0.32))
    ctx.closePath(); ctx.fillPath()

    // Pose 1: arms level, fingertips on the square's sides; legs together, feet on the base.
    limb(shoulderL, CGPoint(x: left + 8, y: shoulderY + 10), 30, 12)
    limb(shoulderR, CGPoint(x: right - 8, y: shoulderY + 10), 30, 12)
    limb(hipL, CGPoint(x: 512 - 30, y: bottom - 8), 40, 16)
    limb(hipR, CGPoint(x: 512 + 30, y: bottom - 8), 40, 16)

    // Pose 2: arms raised to about head height and legs spread, hands and feet on the circle.
    limb(shoulderL, onCircle(180 + 40), 30, 12)
    limb(shoulderR, onCircle(-40), 30, 12)
    limb(hipL, onCircle(90 + 28), 40, 16)
    limb(hipR, onCircle(90 - 28), 40, 16)

    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = CommandLine.arguments[1]
// Light: sepia ink on parchment.
render(Style(background: [rgb(0xF1E3C4), rgb(0xC9A974)], ink: rgb(0x6B4423, 0.85), figure: rgb(0x4A2D14)),
       to: out + "/AppIcon.png")
// Dark: parchment-coloured ink on deep brown.
render(Style(background: [rgb(0x3A2716), rgb(0x150D06)], ink: rgb(0xD9BF8C, 0.8), figure: rgb(0xF0DDB5)),
       to: out + "/AppIcon-Dark.png")
// Tinted: grayscale; the system applies the tint.
render(Style(background: [rgb(0x2A2A2A), rgb(0x000000)], ink: rgb(0xBFBFBF), figure: rgb(0xFFFFFF)),
       to: out + "/AppIcon-Tinted.png")
print("rendered")
