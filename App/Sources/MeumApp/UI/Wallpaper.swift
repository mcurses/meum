// Wallpaper glass: the desktop picture, blurred and anchored to screen coordinates, under every card.
// A minimal port of ~/code/wallpaper-glass via spikes/floating-layout (defaults: blur 4 pt, tint 0.35).

import AppKit
import CoreImage

@MainActor
final class Wallpaper {
    static let shared = Wallpaper()
    static let defaultBlur: CGFloat = 4
    static let defaultTint: CGFloat = 0.35

    private let ci = CIContext(options: [.cacheIntermediates: false])
    private(set) var image: CGImage?
    /// The screen the image was rendered for, in AppKit global coordinates.
    private(set) var screenFrame: NSRect = .zero
    var blur: CGFloat = Wallpaper.defaultBlur
    var tint: CGFloat = Wallpaper.defaultTint

    /// Renders the screen's desktop picture at backing resolution, aspect-filled like the desktop, blurred.
    /// Dynamic (HEIC) and video wallpapers that `desktopImageURL` does not cover fall back to no image
    /// (the cards then show the tint over a dark fill).
    func load(for screen: NSScreen) {
        screenFrame = screen.frame
        let ws = NSWorkspace.shared
        guard let url = ws.desktopImageURL(for: screen),
              let ns = NSImage(contentsOf: url),
              let img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            image = nil
            return
        }
        let o = ws.desktopImageOptions(for: screen) ?? [:]
        let clipping = (o[.allowClipping] as? NSNumber)?.boolValue ?? true
        let scale = screen.backingScaleFactor
        let pw = Int(screen.frame.width * scale), ph = Int(screen.frame.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        let W = CGFloat(pw), H = CGFloat(ph), iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = clipping ? max(W / iw, H / ih) : min(W / iw, H / ih)
        ctx.draw(img, in: CGRect(x: (W - iw * s) / 2, y: (H - ih * s) / 2, width: iw * s, height: ih * s))
        guard var out = ctx.makeImage() else { return }
        if blur > 0 {
            let input = CIImage(cgImage: out)
            let b = input.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale)).cropped(to: input.extent)
            if let c = ci.createCGImage(b, from: input.extent) { out = c }
        }
        image = out
    }
}
