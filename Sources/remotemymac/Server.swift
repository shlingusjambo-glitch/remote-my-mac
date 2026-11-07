import Foundation
import Network
import CryptoKit
import IOKit.pwr_mgt

final class Server {
    var cfg: Config
    let q = DispatchQueue(label: "rmm.core")
    let limiter = Limiter()
    let tokens = TokenStore()
    let capture = Capture()
    let input = InputInjector()
    let cursor = CursorWatcher()
    let clip = ClipboardSync()
    private var listener: NWListener?
    private(set) var active: Conn?
    private var unauthCount = 0
    private var verifying = 0
    private var sleepLock: IOPMAssertionID = 0
    private var conns: [ObjectIdentifier: Conn] = [:]

    init(cfg: Config) { self.cfg = cfg }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true          // no Nagle batching: send every frame immediately
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
        // Loopback only: the ONLY way in is the Cloudflare Tunnel (cloudflared connects from this machine).
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: cfg.port)!)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] nw in
            guard let self else { nw.cancel(); return }
            if self.unauthCount >= 30 { nw.cancel(); return }
            self.unauthCount += 1
            let c = Conn(nw, self)
            self.conns[ObjectIdentifier(c)] = c
            c.start()
        }
        l.stateUpdateHandler = { s in log("listener: \(s)") }
        l.start(queue: q)
        listener = l
    }

    func connClosed(_ c: Conn, wasAuthed: Bool) {
        conns[ObjectIdentifier(c)] = nil
        if !wasAuthed { unauthCount = max(0, unauthCount - 1) }
        if active === c {
            active = nil
            capture.detach(c)
            cursor.stop(); clip.stop()
            if sleepLock != 0 { IOPMAssertionRelease(sleepLock); sleepLock = 0 }
            input.releaseAll()
            if let t = c.token { tokens.touch(t, live: false) }
        }
    }

    func promote(_ c: Conn) {
        unauthCount = max(0, unauthCount - 1)
        if let old = active, old !== c { old.finish(["t": "kicked"]) }
        active = c
        if sleepLock == 0 {      // keep the Mac awake while someone is connected
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "RemoteMyMac session" as CFString, &sleepLock)
        }
        cursor.start { [weak c] m in c?.sendJSON(m) }
        clip.start { [weak c] m in if c?.clipOn == true { c?.sendJSON(m) } }
    }

    func verifyPassword(_ pw: String, totp: String, ip: String, done: @escaping (Bool) -> Void) {
        guard verifying < 2 else { done(false); return }      // bound concurrent 600k-round hashes
        verifying += 1
        let cfg = self.cfg
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let h = Crypto.derive(pw, salt: cfg.salt, iterations: cfg.iterations)
            var ok = Crypto.constantTimeEqual(h, cfg.hash)
            var counter: Int64 = 0
            if let secret = cfg.totpSecret {
                if let c = TOTP.verify(secret: secret, input: totp, after: cfg.lastTotpCounter) { counter = c } else { ok = false }
            }
            // Uniform response time regardless of which factor failed.
            let pad = max(0, 0.6 - Date().timeIntervalSince(started))
            self.q.asyncAfter(deadline: .now() + pad) {
                self.verifying -= 1
                if ok && counter > 0 { self.cfg.lastTotpCounter = counter; try? self.cfg.save() }
                done(ok)
            }
        }
    }
}

final class Conn {
    let nw: NWConnection
    unowned let server: Server
    private var buf: [UInt8] = []
    private var isWS = false
    private(set) var authed = false
    var token: String?
    var ip = "unknown"
    var audioOn = true
    var clipOn = true
    private var lastSeen = Date()
    private var closed = false
    private let lock = NSLock()
    private var pending = 0
    private var timer: DispatchSourceTimer?

    init(_ nw: NWConnection, _ s: Server) { self.nw = nw; self.server = s }

    private var seqSent: UInt32 = 0, seqAcked: UInt32 = 0
    var backlogged: Bool { lock.lock(); defer { lock.unlock() }; return pending > 300_000 }
    /// Video flow control: don't let more than a few unacknowledged frames pile up in the pipe.
    var videoBacklogged: Bool { lock.lock(); defer { lock.unlock() }; return pending > 300_000 || seqSent &- seqAcked > 5 }
    func nextSeq() -> UInt32 { lock.lock(); defer { lock.unlock() }; seqSent &+= 1; return seqSent }
    private func ack(_ s: UInt32) { lock.lock(); if s &- seqAcked <= seqSent &- seqAcked { seqAcked = s }; lock.unlock() }

    func start() {
        nw.stateUpdateHandler = { [weak self] st in
            switch st { case .failed, .cancelled: self?.close(); default: break }
        }
        nw.start(queue: server.q)
        let t = DispatchSource.makeTimerSource(queue: server.q)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let idle = Date().timeIntervalSince(self.lastSeen)
            if (!self.authed && idle > 10) || idle > 45 { self.close() }   // pre-auth sockets live 10s max
        }
        t.resume(); timer = t
        receive()
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self, !self.closed else { return }
            if let d = data, !d.isEmpty {
                self.lastSeen = Date()
                self.buf.append(contentsOf: d)
                self.isWS ? self.parseFrames() : self.parseHTTP()
            }
            if err != nil || done { self.close(); return }
            if !self.closed { self.receive() }
        }
    }

    func close() {
        if closed { return }
        closed = true
        timer?.cancel()
        let was = authed
        server.q.async { self.server.connClosed(self, wasAuthed: was) }
        nw.cancel()
    }

    // MARK: HTTP

    private func parseHTTP() {
        if buf.count > 8192 { close(); return }
        let sep: [UInt8] = [13, 10, 13, 10]
        guard let idx = find(sep) else { return }
        let head = String(decoding: buf[0..<idx], as: UTF8.self)
        buf.removeSubrange(0..<(idx + 4))
        var lines = head.components(separatedBy: "\r\n")
        let reqLine = lines.removeFirst().split(separator: " ")
        guard reqLine.count == 3, reqLine[0] == "GET" else { return respond(405, "text/plain", "Method Not Allowed", close: true) }
        var h: [String: String] = [:]
        for l in lines { if let c = l.firstIndex(of: ":") {
            h[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }

        // Host allow-list (defeats DNS rebinding / stray vhosts).
        let host = (h["host"] ?? "").lowercased().split(separator: ":").first.map(String.init) ?? ""
        guard host == server.cfg.hostname.lowercased() || host == "localhost" || host == "127.0.0.1" else {
            return respond(421, "text/plain", "Misdirected Request", close: true)
        }
        ip = h["cf-connecting-ip"] ?? "local"
        let path = String(reqLine[1].split(separator: "?").first ?? "/")

        if h["upgrade"]?.lowercased() == "websocket" {
            guard path == "/ws", let key = h["sec-websocket-key"], h["sec-websocket-version"] == "13" else {
                return respond(400, "text/plain", "Bad Request", close: true)
            }
            // Same-origin only: blocks cross-site WebSocket hijacking.
            guard let origin = h["origin"], let oh = URL(string: origin)?.host?.lowercased(), oh == host else {
                return respond(403, "text/plain", "Forbidden", close: true)
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            nw.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            isWS = true
            if !buf.isEmpty { parseFrames() }
            return
        }
        switch path {
        case "/": respond(200, "text/html; charset=utf-8", WebAssets.html)
        case "/app.js": respond(200, "text/javascript; charset=utf-8", WebAssets.js)
        case "/app.css": respond(200, "text/css; charset=utf-8", WebAssets.css)
        default: respond(404, "text/plain", "Not Found", close: true)
        }
    }

    private func find(_ pat: [UInt8]) -> Int? {
        guard buf.count >= pat.count else { return nil }
        for i in 0...(buf.count - pat.count) where Array(buf[i..<(i + pat.count)]) == pat { return i }
        return nil
    }

    private func respond(_ code: Int, _ type: String, _ body: String, close shut: Bool = true) {
        let b = Data(body.utf8)
        let head = "HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code))\r\n" +
            "Content-Type: \(type)\r\nContent-Length: \(b.count)\r\nConnection: close\r\nCache-Control: no-store\r\n" +
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n" +
            "X-Frame-Options: DENY\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\n" +
            "Strict-Transport-Security: max-age=63072000; includeSubDomains\r\nCross-Origin-Opener-Policy: same-origin\r\nCross-Origin-Resource-Policy: same-origin\r\n" +
            "Permissions-Policy: camera=(), microphone=(), geolocation=(), autoplay=(self)\r\n\r\n"
        nw.send(content: Data(head.utf8) + b, completion: .contentProcessed { [weak self] _ in if shut { self?.close() } })
    }

    // MARK: WebSocket

    private func parseFrames() {
        while !closed {
            guard buf.count >= 2 else { return }
            let b0 = buf[0], b1 = buf[1]
            let fin = b0 & 0x80 != 0, op = b0 & 0x0f, masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7f), off = 2
            if len == 126 { guard buf.count >= 4 else { return }; len = Int(buf[2]) << 8 | Int(buf[3]); off = 4 }
            else if len == 127 { close(); return }
            guard masked, fin, len <= 65000 else { close(); return }    // clients must mask; no fragmentation; tiny frames
            guard buf.count >= off + 4 + len else { return }
            let mask = Array(buf[off..<(off + 4)])
            var payload = Array(buf[(off + 4)..<(off + 4 + len)])
            for i in 0..<len { payload[i] ^= mask[i & 3] }
            buf.removeSubrange(0..<(off + 4 + len))
            switch op {
            case 1: handleText(String(decoding: payload, as: UTF8.self))
            case 8: close(); return
            case 9: sendFrame(10, Data(payload))
            case 10: break
            default: close(); return
            }
        }
    }

    private func sendFrame(_ op: UInt8, _ payload: Data) {
        if closed { return }
        var h = Data([0x80 | op])
        let n = payload.count
        if n < 126 { h.append(UInt8(n)) }
        else if n <= 0xffff { h.append(126); h.append(UInt8(n >> 8)); h.append(UInt8(n & 0xff)) }
        else { h.append(127); for i in (0..<8).reversed() { h.append(UInt8((n >> (8 * i)) & 0xff)) } }
        lock.lock(); pending += n; lock.unlock()
        nw.send(content: h + payload, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pending -= n; self.lock.unlock()
        })
    }

    func sendJSON(_ o: [String: Any]) {
        if let d = try? JSONSerialization.data(withJSONObject: o) { sendFrame(1, d) }
    }
    func sendBinary(_ d: Data) { sendFrame(2, d) }

    /// Send a final message, then close once it has actually been flushed.
    func finish(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o), !closed else { close(); return }
        var h = Data([0x81, UInt8(d.count)])
        if d.count >= 126 { h = Data([0x81, 126, UInt8(d.count >> 8), UInt8(d.count & 0xff)]) }
        nw.send(content: h + d, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    // MARK: protocol

    private func handleText(_ s: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any],
              let t = o["t"] as? String else { return }
        if !authed { return handleAuth(t, o) }
        switch t {
        case "ping":
            if let tk = token { server.tokens.touch(tk, live: true) }
            sendJSON(["t": "pong", "c": o["c"] ?? 0])
        case "a": if let s = o["s"] as? Int { ack(UInt32(truncatingIfNeeded: s)) }
        case "view":
            let w = (o["w"] as? Double).map(Int.init) ?? 1280, h = (o["h"] as? Double).map(Int.init) ?? 720
            let cw = (o["cw"] as? Double).map(Int.init) ?? 0, ch = (o["ch"] as? Double).map(Int.init) ?? 0
            server.capture.attach(self, viewW: min(max(w, 320), 8192), viewH: min(max(h, 240), 8192), cssW: cw, cssH: ch, zoom: min(max((o["z"] as? Double) ?? 1, 0.5), 3), quality: min(max((o["q"] as? Int) ?? 1, 0), 2))
        case "key": server.capture.requestKeyframe()
        case "audio": audioOn = (o["on"] as? Bool) ?? true
        case "clipcfg": clipOn = (o["on"] as? Bool) ?? true
        case "clip": if clipOn, let t = o["text"] as? String, t.utf8.count <= ClipboardSync.maxIncoming { server.clip.set(t) }
        case "m", "r", "d", "u", "w", "k", "release": server.input.handle(t, o)
        case "logout":
            if let tk = token { server.tokens.revoke(tk) }
            close()
        default: break
        }
    }

    private func handleAuth(_ t: String, _ o: [String: Any]) {
        if let wait = server.limiter.lockout(ip) {
            finish(["t": "locked", "retry": Int(wait)]); return
        }
        switch t {
        case "resume":
            if let tk = o["token"] as? String, tk.count == 64, server.tokens.redeem(tk) {
                token = tk; finishLogin(tk, fresh: false)
            } else { server.limiter.fail(ip); finish(["t": "fail"]) }
        case "auth":
            guard let pw = o["password"] as? String, pw.count > 0, pw.utf8.count <= 256 else {
                server.limiter.fail(ip); finish(["t": "fail"]); return
            }
            let totp = (o["totp"] as? String)?.filter(\.isNumber) ?? ""
            server.verifyPassword(pw, totp: String(totp.prefix(6)), ip: ip) { [weak self] ok in
                guard let self, !self.closed else { return }
                if ok {
                    self.server.limiter.success(self.ip)
                    let tk = self.server.tokens.issue(); self.token = tk
                    self.finishLogin(tk, fresh: true)
                } else {
                    self.server.limiter.fail(self.ip)
                    log("failed login from \(self.ip)")
                    self.finish(["t": "fail"])
                }
            }
        default: break
        }
    }

    private func finishLogin(_ tk: String, fresh: Bool) {
        authed = true
        server.promote(self)
        log("login ok from \(ip) (\(fresh ? "password" : "resume"))")
        let b = server.input.bounds
        sendJSON(["t": "ok", "token": tk, "dw": Int(b.width), "dh": Int(b.height)])
    }
}
