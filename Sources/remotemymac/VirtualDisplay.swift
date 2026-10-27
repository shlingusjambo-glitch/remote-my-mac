import Foundation
import CoreGraphics
import CVirtualDisplay

/// A virtual monitor sized exactly like the viewer's browser tab. The physical screen is set to MIRROR it,
/// so the whole desktop adopts the tab's shape and the stream has no letterbox bars.
/// Everything is app-scoped: macOS drops the mirror and the display if we quit or crash.
final class VirtualDisplay {
    static let shared = VirtualDisplay()
    private var vd: CGVirtualDisplay?
    private var physical: CGDirectDisplayID = 0
    private var curW = 0, curH = 0
    private var lastChange = Date.distantPast
    private(set) var id: CGDirectDisplayID = 0
    var active: Bool { vd != nil }

    /// The display being captured / controlled.
    static var target: CGDirectDisplayID { shared.active ? shared.id : CGMainDisplayID() }

    private func settings(_ w: Int, _ h: Int) -> CGVirtualDisplaySettings {
        let s = CGVirtualDisplaySettings()
        s.hiDPI = w <= 1920 ? 1 : 0
        s.modes = [CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: 60)]
        return s
    }

    private func mirror(_ display: CGDirectDisplayID, of master: CGDirectDisplayID) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, display, master)
        if CGCompleteDisplayConfiguration(cfg, .forAppOnly) != .success { CGCancelDisplayConfiguration(cfg) }
    }

    @discardableResult
    func ensure(cssW: Int, cssH: Int, zoom: Double = 1, maxW: Double = 3840, mirror doMirror: Bool = true) -> Bool {
        guard cssW > 0, cssH > 0 else { return false }
        // Logical desktop = tab size / zoom (so 1 point ~ 1 browser pixel at zoom 1), same exact shape,
        // capped at 3840 wide / 2160 tall and at least 800 wide.
        let aspect = Double(cssW) / Double(cssH)
        var lw = min(max(Double(cssW) / zoom, 800), maxW), lh = lw / aspect
        if lh > 2160 { lh = 2160; lw = lh * aspect }
        let w = max(2, Int(lw) & ~1), h = max(2, Int(lh) & ~1)
        if vd != nil {
            let close = abs(w - curW) * 100 <= curW * 3 && abs(h - curH) * 100 <= curH * 3
            if close || Date().timeIntervalSince(lastChange) < 1 { return true }   // avoid flapping while resizing
            guard vd!.apply(settings(w, h)) else { return true }
            curW = w; curH = h; lastChange = Date()
            log("virtual display resized to \(w)x\(h)")
            return true
        }
        let d = CGVirtualDisplayDescriptor()
        d.name = "RemoteMyMac"
        d.maxPixelsWide = 3840; d.maxPixelsHigh = 2880
        d.sizeInMillimeters = CGSize(width: Double(w) * 0.2, height: Double(h) * 0.2)
        d.productID = 0x7E57; d.vendorID = 0x7E57; d.serialNum = 1
        d.queue = DispatchQueue(label: "rmm.vdisplay")
        d.terminationHandler = { _, _ in }
        guard let v = CGVirtualDisplay(descriptor: d) else { log("virtual display unavailable; falling back"); return false }
        guard v.displayID != 0, v.apply(settings(w, h)) else { log("virtual display unavailable; falling back"); return false }
        physical = CGMainDisplayID()
        vd = v; id = v.displayID; curW = w; curH = h; lastChange = Date()
        log("virtual display \(id) created at \(w)x\(h) for \(cssW)x\(cssH) tab; pixels \(CGDisplayPixelsWide(v.displayID))x\(CGDisplayPixelsHigh(v.displayID))")
        usleep(600_000)
        if doMirror { mirror(physical, of: id) }
        return true
    }

    func teardown() {
        guard vd != nil else { return }
        if physical != 0 { mirror(physical, of: kCGNullDirectDisplay) }
        vd = nil; id = 0; curW = 0; curH = 0
        log("virtual display removed; screen restored")
    }
}
