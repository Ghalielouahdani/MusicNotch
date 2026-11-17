import AppKit
import CoreImage

/// Downloads and caches artwork and playlist covers.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    func cached(_ url: URL?) -> NSImage? {
        url.flatMap { cache.object(forKey: $0 as NSURL) }
    }

    func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }

        let task = inFlight[url] ?? Task {
            try? await URLSession.shared.data(from: url).0
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil

        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

extension NSImage {
    /// The average color, lifted so it stays visible on black. Used to tint the visualizer.
    var accentColor: NSColor? {
        guard let tiff = tiffRepresentation, let input = CIImage(data: tiff) else { return nil }
        let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            kCIInputExtentKey: CIVector(cgRect: input.extent),
        ])
        guard let output = filter?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8, colorSpace: nil
        )
        let color = NSColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: 1
        )
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(1, saturation * 1.25),
            brightness: max(brightness, 0.75),
            alpha: 1
        )
    }
}

extension NSImage {
    /// The cover's main colors, most prominent first, distinct from each other
    /// and toned for a background behind white text. Always `count` colors.
    func palette(count: Int = 4) -> [NSColor] {
        let side = 32
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return [] }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return [] }

        // Group pixels into coarse color bins, keeping each bin's average color.
        struct Bin { var r = 0.0, g = 0.0, b = 0.0, count = 0.0 }
        var bins: [Int: Bin] = [:]
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for index in 0..<(side * side) {
            let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1]), b = Int(pixels[index * 4 + 2])
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            var bin = bins[key, default: Bin()]
            bin.r += Double(r); bin.g += Double(g); bin.b += Double(b); bin.count += 1
            bins[key] = bin
        }

        // Rank by size, nudged toward colorful bins so a vivid detail beats a large gray.
        let candidates: [(color: NSColor, score: Double)] = bins.values.map { bin in
            let color = NSColor(
                red: bin.r / bin.count / 255, green: bin.g / bin.count / 255, blue: bin.b / bin.count / 255, alpha: 1
            )
            return (color, bin.count * (0.35 + color.saturationComponent))
        }
        .sorted { $0.score > $1.score }

        var picked: [NSColor] = []
        for candidate in candidates where picked.count < count {
            if picked.allSatisfy({ $0.distance(to: candidate.color) > 0.22 }) { picked.append(candidate.color) }
        }
        guard !picked.isEmpty else { return [] }
        // A plain cover: fill with lighter and darker shades of what's there.
        var shade = 0
        while picked.count < count {
            let base = picked[shade % picked.count]
            picked.append(base.adjusted(brightness: shade.isMultiple(of: 2) ? -0.18 : 0.15))
            shade += 1
        }
        return picked.map { $0.toned() }
    }
}

private extension NSColor {
    func distance(to other: NSColor) -> Double {
        let a = usingColorSpace(.deviceRGB) ?? self, b = other.usingColorSpace(.deviceRGB) ?? other
        let dr = a.redComponent - b.redComponent, dg = a.greenComponent - b.greenComponent, db = a.blueComponent - b.blueComponent
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    func adjusted(brightness delta: CGFloat) -> NSColor {
        let color = usingColorSpace(.deviceRGB) ?? self
        return NSColor(hue: color.hueComponent, saturation: color.saturationComponent,
                       brightness: min(1, max(0, color.brightnessComponent + delta)), alpha: 1)
    }

    /// Keeps a background color out of pure black and blown-out white.
    func toned() -> NSColor {
        let color = usingColorSpace(.deviceRGB) ?? self
        return NSColor(hue: color.hueComponent, saturation: min(1, color.saturationComponent * 1.1),
                       brightness: min(0.82, max(0.18, color.brightnessComponent)), alpha: 1)
    }
}
