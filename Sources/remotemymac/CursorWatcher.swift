import AppKit

/// Watches the Mac's current system cursor and reports each change (image + hotspot) to the viewer,
/// so the browser pointer matches (arrow, I-beam, hand, resize...). Cursor drawing itself stays local = zero lag.
final class CursorWatcher {
    private var timer: DispatchSourceTimer?
    private var lastKey = ""

    func start(_ send: @escaping ([String: Any]) -> Void) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.poll(send) }
        t.resume(); timer = t
    }

    func stop() { timer?.cancel(); timer = nil; lastKey = "" }

    private func poll(_ send: ([String: Any]) -> Void) {
        guard let c = NSCursor.currentSystem else { return }
        let img = c.image
        guard img.size.width > 0 else { return }
        let reps = img.representations.compactMap { $0 as? NSBitmapImageRep }.filter { $0.pixelsWide <= 128 }
        guard let rep = reps.min(by: { abs($0.pixelsWide - Int(img.size.width * 2)) < abs($1.pixelsWide - Int(img.size.width * 2)) }),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let key = "\(png.count)-\(png.hashValue)-\(c.hotSpot.x)-\(c.hotSpot.y)"
        guard key != lastKey else { return }
        lastKey = key
        send(["t": "cur", "png": png.base64EncodedString(), "s": Double(rep.pixelsWide) / Double(img.size.width),
              "hx": Int(c.hotSpot.x), "hy": Int(c.hotSpot.y)])
    }
}
