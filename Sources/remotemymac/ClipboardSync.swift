import AppKit

/// Text clipboard passthrough. Mac -> browser: reports new copies (skipping password-manager "concealed" items).
/// Browser -> Mac: `set` writes the pasteboard just before the viewer's paste keystroke arrives.
final class ClipboardSync {
    private var timer: DispatchSourceTimer?
    private var lastCount = 0
    static let maxIncoming = 60_000, maxOutgoing = 1_000_000

    func start(_ send: @escaping ([String: Any]) -> Void) {
        stop()
        DispatchQueue.main.async {
            self.lastCount = NSPasteboard.general.changeCount        // don't push whatever was already there
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
            t.setEventHandler { [weak self] in self?.poll(send) }
            t.resume(); self.timer = t
        }
    }

    func stop() { DispatchQueue.main.async { self.timer?.cancel(); self.timer = nil } }

    func set(_ text: String) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(text, forType: .string)
            self.lastCount = pb.changeCount                           // our own write: don't echo it back
        }
    }

    private func poll(_ send: ([String: Any]) -> Void) {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        let types = pb.types?.map(\.rawValue) ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.isEmpty, s.utf8.count <= Self.maxOutgoing else { return }
        send(["t": "clip", "text": s])
    }
}
