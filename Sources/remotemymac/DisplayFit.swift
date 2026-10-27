import Foundation
import CoreGraphics

/// Switches the Mac's display to the mode whose shape best matches the viewer's browser tab,
/// so the stream fills the tab with no bars. Changes are app-scoped: macOS reverts them if we exit or crash.
enum DisplayFit {
    private static var original: CGDisplayMode?
    private static var lastChange = Date.distantPast

    private static func apply(_ mode: CGDisplayMode, _ id: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
        if CGCompleteDisplayConfiguration(cfg, .forAppOnly) != .success { CGCancelDisplayConfiguration(cfg) }
    }

    static func fit(cssW: Int, cssH: Int) {
        guard cssW > 0, cssH > 0, Date().timeIntervalSince(lastChange) > 3 else { return }
        let id = CGMainDisplayID()
        guard let cur = CGDisplayCopyDisplayMode(id) else { return }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return }
        let target = Double(cssW) / Double(cssH)
        var best: CGDisplayMode?, bestScore = Double.infinity
        for m in modes where m.isUsableForDesktopGUI() && m.width >= 1024 {
            let aerr = abs(Double(m.width) / Double(m.height) - target) / target
            guard aerr < 0.08 else { continue }
            let hidpi = m.pixelWidth >= m.width * 2 ? 0.0 : 0.15          // prefer sharp (Retina) modes
            let score = aerr * 10 + abs(log(Double(m.width) / Double(cssW))) + hidpi   // and a size readable in the tab
            if score < bestScore { bestScore = score; best = m }
        }
        guard let b = best, !(b.width == cur.width && b.height == cur.height && b.pixelWidth == cur.pixelWidth) else { return }
        if original == nil { original = cur }
        lastChange = Date()
        log("display: \(cur.width)x\(cur.height) -> \(b.width)x\(b.height) to fit \(cssW)x\(cssH) tab")
        apply(b, id)
    }

    static func restore() {
        guard let o = original else { return }
        original = nil; lastChange = Date.distantPast
        log("display: restoring \(o.width)x\(o.height)")
        apply(o, CGMainDisplayID())
    }
}
