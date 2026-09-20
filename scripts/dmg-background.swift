#!/usr/bin/env swift
// Draws the backdrop the disk-image window shows behind its two icons: the app's name and a line about it on a
// charcoal header, then a light stage where the app and the Applications folder sit, with a streak of light
// pointing from one to the other. The icons themselves are real files, placed by the image's own layout; this
// only paints what is behind them.
//
//   swift dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]
//
// Finder draws this image at its natural size, anchored to the top-left corner of the window's content area,
// and clips whatever its own bars leave no room for at the bottom. So everything that means something sits in
// the top `contentFloor` points, and below that the image is one flat colour that a clip cannot be seen in.
// The icon centres below are the ones `scripts/dmg-settings.py` positions the two files at; both must agree
// or the arrow misses the icons.

import AppKit
import Foundation

// The window, in points, and the band of it a viewer is sure to see.
let windowSize = CGSize(width: 660, height: 480)
let contentFloor: CGFloat = 340

// Where the two icons sit, and the icon size the layout asks Finder for. Finder draws each label just below
// its icon, in dark text, ending about `labelDepth` under the icon's bottom edge: with these numbers the
// labels land around y 314 to 332, on the light stage and above the floor.
let appIconCentre = CGPoint(x: 165, y: 246)
let dropIconCentre = CGPoint(x: 495, y: 246)
let iconSide: CGFloat = 128
let labelDepth: CGFloat = 24
guard max(appIconCentre.y, dropIconCentre.y) + iconSide / 2 + labelDepth <= contentFloor else {
    die("the icon labels would sit below the content floor, where Finder may clip them")
}

// The header is the slab of the app icon; the stage below the horizon is where Finder's dark labels read.
let horizon: CGFloat = 148
let titleCentre: CGFloat = 60
let descriptionCentre: CGFloat = 106

// The eight LEDs of the app icon, in the order the strip shows them. The name is set in them.
let strip: [NSColor] = ["FF4B55", "FF8A3C", "FFD23F", "3DDC84", "2FD6E0", "3B8BFF", "8B6BFF", "F45BD6"].map(colour)

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("dmg-background: " + message + "\n").utf8))
    exit(1)
}

/// "#RRGGBB" or "RRGGBB".
func colour(_ hex: String) -> NSColor {
    let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard text.count == 6, let value = UInt32(text, radix: 16) else { die("colour must be six hex digits, got \(hex)") }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green: CGFloat((value >> 8) & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255,
                   alpha: 1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    die("usage: dmg-background.swift <name> <accent hex> <out.png> [out@2x.png] [description]")
}
let appName = arguments[1]
let accent = colour(arguments[2])
let description = arguments.count >= 6 ? arguments[5] : "What Claude Code is doing, on a SidePulse strip"

let slabTop = colour("2B2D37")
let slabBottom = colour("16171D")
let stage = colour("ECEDF1")
let descriptionColour = colour("9DA1AD")

/// A cubic Bézier, sampled where the streak needs it.
struct Cubic {
    let p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        return CGPoint(x: x, y: y)
    }

    /// The unit tangent, pointing the way the curve runs.
    func direction(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
        let y = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
        let length = max(hypot(x, y), 0.0001)
        return CGPoint(x: x / length, y: y / length)
    }
}

/// The streak: a body along the curve that widens from a rounded tail to `headHalfWidth` where the head
/// starts, then a swept head whose back is notched where the body enters it. The head is anchored
/// `headOverlap` behind the body's end so the body is buried in it rather than butted against its back;
/// `headLength` is the run from the body's end to the tip. Both outlines wind clockwise so one clip holds
/// the union.
func streakPath(along curve: Cubic, tailHalfWidth: CGFloat, headHalfWidth: CGFloat, headLength: CGFloat,
                headHalfSpan: CGFloat, headSweep: CGFloat, headNotch: CGFloat, headOverlap: CGFloat) -> CGPath {
    let samples = 96
    var upper: [CGPoint] = []
    var lower: [CGPoint] = []
    for index in 0...samples {
        let t = CGFloat(index) / CGFloat(samples)
        let eased = t * t * (3 - 2 * t)
        let half = tailHalfWidth + (headHalfWidth - tailHalfWidth) * eased
        let p = curve.point(t)
        let d = curve.direction(t)
        let n = CGPoint(x: -d.y, y: d.x)
        upper.append(CGPoint(x: p.x + n.x * half, y: p.y + n.y * half))
        lower.append(CGPoint(x: p.x - n.x * half, y: p.y - n.y * half))
    }
    let path = CGMutablePath()
    path.move(to: upper[0])
    for point in upper.dropFirst() { path.addLine(to: point) }
    for point in lower.reversed() { path.addLine(to: point) }
    let tailDirection = curve.direction(0)
    let tailAngle = atan2(-tailDirection.x, tailDirection.y)
    path.addArc(center: curve.point(0), radius: tailHalfWidth,
                startAngle: tailAngle + .pi, endAngle: tailAngle, clockwise: true)
    path.closeSubpath()

    let end = curve.point(1)
    let d = curve.direction(1)
    let n = CGPoint(x: -d.y, y: d.x)
    let anchor = CGPoint(x: end.x - d.x * headOverlap, y: end.y - d.y * headOverlap)
    func at(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x + d.x * along + n.x * across, y: anchor.y + d.y * along + n.y * across)
    }
    path.move(to: at(headOverlap + headLength, 0))
    path.addLine(to: at(-headSweep, -headHalfSpan))
    path.addLine(to: at(headNotch, 0))
    path.addLine(to: at(-headSweep, headHalfSpan))
    path.closeSubpath()
    return path
}

func gradient(_ colours: [NSColor], locations: [CGFloat]? = nil) -> CGGradient {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let cgColours = colours.map { $0.cgColor } as CFArray
    guard let gradient = CGGradient(colorsSpace: space, colors: cgColours, locations: locations)
    else { die("could not build a gradient") }
    return gradient
}

/// One drawing, rendered at whatever scale the caller asks for; the 2x file is drawn again at 2x, not scaled
/// up. CoreGraphics' origin is bottom-left; the constants above read top-down, so `y(_:)` flips them.
func render(scale: CGFloat) -> Data {
    let width = Int(windowSize.width * scale), height = Int(windowSize.height * scale)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { die("could not allocate the bitmap") }
    cg.scaleBy(x: scale, y: scale)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)
    cg.setShouldSmoothFonts(true)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    func y(_ topDown: CGFloat) -> CGFloat { windowSize.height - topDown }

    // The stage: one flat colour over the whole image, so the part Finder clips looks like nothing at all.
    cg.setFillColor(stage.cgColor)
    cg.fill(CGRect(origin: .zero, size: windowSize))

    // The header: the icon's slab, a little lighter at the top like the icon itself.
    cg.saveGState()
    cg.clip(to: CGRect(x: 0, y: y(horizon), width: windowSize.width, height: horizon))
    cg.drawLinearGradient(gradient([slabTop, slabBottom]),
                          start: CGPoint(x: 0, y: y(0)), end: CGPoint(x: 0, y: y(horizon)), options: [])
    cg.restoreGState()

    // The slab casts a short shadow onto the stage, which is what makes the horizon read as an edge.
    cg.saveGState()
    let shadowDepth: CGFloat = 14
    cg.clip(to: CGRect(x: 0, y: y(horizon + shadowDepth), width: windowSize.width, height: shadowDepth))
    cg.drawLinearGradient(gradient([NSColor.black.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0)]),
                          start: CGPoint(x: 0, y: y(horizon)), end: CGPoint(x: 0, y: y(horizon + shadowDepth)),
                          options: [])
    cg.restoreGState()

    // The name, set in the eight LEDs from left to right.
    let titleFont = NSFont.systemFont(ofSize: 44, weight: .bold)
    let title = NSAttributedString(string: appName, attributes: [.font: titleFont, .kern: -0.8])
    let line = CTLineCreateWithAttributedString(title)
    let titleWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let titleLeft = (windowSize.width - titleWidth) / 2
    cg.saveGState()
    cg.textMatrix = .identity
    cg.textPosition = CGPoint(x: titleLeft, y: y(titleCentre) - titleFont.capHeight / 2)
    cg.setTextDrawingMode(.clip)
    CTLineDraw(line, cg)
    cg.drawLinearGradient(gradient(strip),
                          start: CGPoint(x: titleLeft, y: 0), end: CGPoint(x: titleLeft + titleWidth, y: 0),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    // One line about the app, under the name.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let descriptionAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14, weight: .regular),
        .foregroundColor: descriptionColour,
        .paragraphStyle: paragraph,
    ]
    let descriptionHeight = (description as NSString).size(withAttributes: descriptionAttributes).height
    (description as NSString).draw(in: NSRect(x: 0, y: y(descriptionCentre) - descriptionHeight / 2,
                                              width: windowSize.width, height: descriptionHeight),
                                   withAttributes: descriptionAttributes)

    // The streak: it leaves the app's right edge as a thread of light with a slight lift, swells as it
    // crosses, and arrives level at the folder's left edge with a swept head. The colour comes in from the
    // stage at the tail and is the accent by the head.
    let tail = CGPoint(x: appIconCentre.x + iconSide / 2 + 24, y: y(appIconCentre.y))
    let tip = CGPoint(x: dropIconCentre.x - iconSide / 2 - 22, y: y(dropIconCentre.y))
    let headLength: CGFloat = 20
    let bodyEnd = CGPoint(x: tip.x - headLength, y: tip.y)
    let span = bodyEnd.x - tail.x
    let curve = Cubic(p0: tail,
                      p1: CGPoint(x: tail.x + span * 0.4, y: tail.y + 10),
                      p2: CGPoint(x: bodyEnd.x - span * 0.3, y: bodyEnd.y + 4),
                      p3: bodyEnd)
    let streak = streakPath(along: curve, tailHalfWidth: 1.2, headHalfWidth: 4, headLength: headLength,
                            headHalfSpan: 11, headSweep: 4, headNotch: 3, headOverlap: 4)
    cg.saveGState()
    cg.addPath(streak)
    cg.clip()
    let faint = accent.blended(withFraction: 0.5, of: stage) ?? accent
    cg.drawLinearGradient(gradient([faint, accent], locations: [0, 0.75]),
                          start: CGPoint(x: tail.x, y: 0), end: CGPoint(x: tip.x, y: 0),
                          options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    guard let image = cg.makeImage() else { die("could not read the bitmap back") }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = windowSize
    guard let data = bitmap.representation(using: .png, properties: [:]) else { die("could not encode the PNG") }
    return data
}

do {
    try render(scale: 1).write(to: URL(fileURLWithPath: arguments[3]))
    if arguments.count >= 5 { try render(scale: 2).write(to: URL(fileURLWithPath: arguments[4])) }
} catch {
    die("could not write: \(error.localizedDescription)")
}
