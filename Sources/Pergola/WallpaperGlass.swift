import SwiftUI
import AppKit
import CoreImage
import ImageIO

/// The lock screen doesn't let apps' Liquid Glass see the wallpaper behind it (it renders as a flat grey
/// slab there), so on the lock screen Pergola makes its glass from the wallpaper picture itself: it
/// draws the exact patch of wallpaper behind the card, lined up with the real one, then blurs it
/// (Frosted) or keeps it sharp with a slight lens magnification (Clear).
@Observable @MainActor
final class WallpaperBackdrop {
    static let shared = WallpaperBackdrop()

    private(set) var sharp: NSImage?
    private(set) var frosted: NSImage?
    /// The size of the screen the wallpaper fills, in points.
    private(set) var screenSize: CGSize = .zero
    @ObservationIgnored private var loadedKey = ""

    /// Loads (or reloads, if the wallpaper or screen changed) the wallpaper for `screen`.
    func refresh(for screen: NSScreen) {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let size = screen.frame.size
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)|\(size.width)x\(size.height)"
        guard key != loadedKey else { return }
        loadedKey = key
        screenSize = size
        let longest = max(size.width, size.height) * min(screen.backingScaleFactor, 1.5)
        Task.detached(priority: .utility) {
            guard let images = Self.render(url: url, longestSide: longest) else { return }
            await MainActor.run {
                self.sharp = NSImage(cgImage: images.sharp, size: NSSize(width: images.sharp.width, height: images.sharp.height))
                self.frosted = NSImage(cgImage: images.frosted, size: NSSize(width: images.frosted.width, height: images.frosted.height))
            }
        }
    }

    nonisolated private static func render(url: URL, longestSide: CGFloat) -> (sharp: CGImage, frosted: CGImage)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sharp = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Int(longestSide),
              ] as CFDictionary),
              let small = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 480,
              ] as CFDictionary) else { return nil }
        // Frosted: blur a small copy (it's going to be soft anyway), a touch more colourful, like Apple's.
        let input = CIImage(cgImage: small)
        let output = input.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25])
            .cropped(to: input.extent)
        guard let frosted = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return (sharp, frosted)
    }
}

/// The patch of wallpaper directly behind this view. Assumes the view's window covers the screen
/// (true for the lock-screen window), and that the wallpaper fills the screen, centred.
struct WallpaperGlassFill: View {
    var frosted: Bool
    /// Clear glass magnifies what's behind it very slightly, like a lens.
    var lens: CGFloat = 1.035
    private var backdrop: WallpaperBackdrop { .shared }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .global)
            let screen = backdrop.screenSize
            if let image = frosted ? backdrop.frosted : backdrop.sharp, screen.width > 0 {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screen.width, height: screen.height)
                    .clipped()
                    .scaleEffect(frosted ? 1 : lens,
                                 anchor: UnitPoint(x: frame.midX / screen.width, y: frame.midY / screen.height))
                    .offset(x: -frame.minX, y: -frame.minY)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
        .clipped()
    }
}
