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
