// Draws the MusicNotch logo and app icon.
//   swiftc scripts/make-icon.swift -o build/make-icon && build/make-icon
// Writes docs/logo.png and Resources/AppIcon.icns.
import AppKit
import SwiftUI

let canvas: CGFloat = 1024

/// macOS icon grid: an 824 pt squircle centered on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Apple's continuous-corner tile (the same curve as SwiftUI's `.continuous` style).
func squircle(in rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: rect).cgPath
}

/// Same outline as the app's NotchShape: flared top corners, rounded bottom. Top-down coordinates.
func notch(in rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top), control: CGPoint(x: rect.minX + top, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
    path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY), control: CGPoint(x: rect.minX + top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom), control: CGPoint(x: rect.maxX - top, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - top, y: rect.minY))
    path.closeSubpath()
    return path
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ context: CGContext, _ colors: [CGColor], from start: CGPoint, to end: CGPoint, clip: CGPath) {
    context.saveGState()
    context.addPath(clip)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawIcon(in context: CGContext) {
    // Work top-down, like the app's layout.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)

    let tilePath = squircle(in: tile)

    // Soft drop shadow under the tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    context.addPath(tilePath)
    context.setFillColor(color(0x1A0A12))
    context.fillPath()
    context.restoreGState()

    // Wallpaper: warm red fading into deep plum, like a curtain lit from above.
    linearGradient(context, [color(0xE2465E), color(0x8E1F4F), color(0x2A0C2E)],
                   from: CGPoint(x: tile.midX, y: tile.minY), to: CGPoint(x: tile.midX, y: tile.maxY), clip: tilePath)

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    // Light spilling out from under the notch.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFD1DC, 0.42), color(0xFFD1DC, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 250), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 250), endRadius: 430, options: [])

    // The notch, hanging from the top edge, opened just enough to show the song.
    let notchRect = CGRect(x: 262, y: 100, width: 500, height: 176)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x000000, 0.45))
    context.addPath(notch(in: notchRect, top: 30, bottom: 66))
    context.setFillColor(color(0x000000))
    context.fillPath()
    context.restoreGState()

    // Album cover on the left.
    let cover = CGRect(x: 318, y: 146, width: 100, height: 100)
    linearGradient(context, [color(0xFFB199), color(0xFF5E8A), color(0x7B3FE4)],
                   from: CGPoint(x: cover.minX, y: cover.minY), to: CGPoint(x: cover.maxX, y: cover.maxY),
                   clip: rounded(cover, 22))
    context.setFillColor(color(0xFFFFFF, 0.9))
    context.fillEllipse(in: CGRect(x: cover.minX + 56, y: cover.minY + 22, width: 24, height: 24))

    // Visualizer bars on the right.
    let barHeights: [CGFloat] = [50, 92, 68, 38]
    let barWidth: CGFloat = 17, barGap: CGFloat = 13
    var barX: CGFloat = 706 - (barWidth * 4 + barGap * 3)
    for height in barHeights {
        let bar = CGRect(x: barX, y: 196 - height / 2, width: barWidth, height: height)
        linearGradient(context, [color(0xFFC3D2), color(0xFF7FA3)],
                       from: CGPoint(x: bar.midX, y: bar.minY), to: CGPoint(x: bar.midX, y: bar.maxY),
                       clip: rounded(bar, barWidth / 2))
        barX += barWidth + barGap
    }

    // Playlist rows below: the first one already holds the song.
    let rows: [(y: CGFloat, alpha: CGFloat, nameWidth: CGFloat)] = [(392, 0.2, 250), (510, 0.13, 200), (628, 0.075, 230)]
    for (index, row) in rows.enumerated() {
        let rect = CGRect(x: 214, y: row.y, width: 596, height: 92)
        context.addPath(rounded(rect, 30))
        context.setFillColor(color(0xFFFFFF, row.alpha))
        context.fillPath()

        context.addPath(rounded(CGRect(x: rect.minX + 20, y: rect.midY - 29, width: 58, height: 58), 15))
        context.setFillColor(color(0xFFFFFF, index == 0 ? 0.55 : row.alpha * 2.4))
        context.fillPath()

        context.addPath(rounded(CGRect(x: rect.minX + 100, y: rect.midY - 11, width: row.nameWidth, height: 22), 11))
        context.setFillColor(color(0xFFFFFF, index == 0 ? 0.85 : row.alpha * 3))
        context.fillPath()

        if index == 0 {
            let check = CGRect(x: rect.maxX - 82, y: rect.midY - 28, width: 56, height: 56)
            context.setFillColor(color(0x34D17A))
            context.fillEllipse(in: check)
            context.setStrokeColor(color(0xFFFFFF))
            context.setLineWidth(8)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: CGPoint(x: check.minX + 15, y: check.midY + 1))
            context.addLine(to: CGPoint(x: check.minX + 24, y: check.midY + 10))
            context.addLine(to: CGPoint(x: check.minX + 41, y: check.midY - 9))
            context.strokePath()
        }
    }

    // A thin bright rim where light catches the tile's top edge.
    context.addPath(tilePath)
    context.setStrokeColor(color(0xFFFFFF, 0.12))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.interpolationQuality = .high
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appending(path: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
try FileManager.default.createDirectory(at: root.appending(path: "docs"), withIntermediateDirectories: true)
try render(size: 512).write(to: root.appending(path: "docs/logo.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote docs/logo.png and Resources/AppIcon.icns" : "iconutil failed")
