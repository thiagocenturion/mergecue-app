import CoreGraphics
import Foundation
import ImageIO
import MergeCueCore

/// Synthetic avatars for preview data (D58): every preview person gets an `https://avatars.preview.invalid/…` URL
/// (the `.invalid` TLD never resolves) and the preview store draws a symmetric pattern for it in-process, so
/// snapshots show the image path without any network access and nobody's real face.
extension MergeCuePreview {
    nonisolated static let avatarHost = "avatars.preview.invalid"

    /// `https://avatars.preview.invalid/<id>.png`.
    nonisolated static func avatarURL(_ id: String) -> URL? {
        URL(string: "https://\(avatarHost)/\(id).png")
    }

    /// Memory-only store backed by `PreviewAvatarLoader`.
    public static let avatarImages = AvatarImageStore(directory: nil, loader: PreviewAvatarLoader())
}

extension AppModel {
    /// The avatar store the UI uses for this backend: the shared cache for live data, synthetic images for preview
    /// data, none for demo data (its fixture URLs name real hosts and people, so it draws initials).
    public var avatarImages: AvatarImageStore? {
        switch mode {
        case .live: .shared
        case .preview: MergeCuePreview.avatarImages
        case .demo: nil
        }
    }
}

/// Draws a 5×5 mirrored pattern seeded by the URL's file name. Refuses every URL outside the preview host.
nonisolated struct PreviewAvatarLoader: AvatarImageLoading {
    enum LoadError: Error { case notPreview, encoding }

    func imageData(for url: URL) async throws -> Data {
        guard url.host() == MergeCuePreview.avatarHost else { throw LoadError.notPreview }
        guard let data = Self.png(seed: url.deletingPathExtension().lastPathComponent) else { throw LoadError.encoding }
        return data
    }

    static func png(seed: String, pixels: Int = 120) -> Data? {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        let hue = CGFloat(hash % 360) / 360
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(rgb(hue: hue, saturation: 0.18, brightness: 0.96))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.setFillColor(rgb(hue: hue, saturation: 0.55, brightness: 0.72))
        let cell = CGFloat(pixels) / 6
        let inset = cell / 2
        var bits = hash >> 9
        for row in 0..<5 {
            for column in 0..<3 {
                defer { bits >>= 1 }
                guard bits & 1 == 1 else { continue }
                for x in Set([column, 4 - column]) {
                    context.fill(CGRect(x: inset + CGFloat(x) * cell, y: inset + CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func rgb(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> CGColor {
        let h = hue * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(h) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        return CGColor(srgbRed: r + m, green: g + m, blue: b + m, alpha: 1)
    }
}
