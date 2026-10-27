import Foundation
import CommonCrypto
import CryptoKit
import Security

enum Crypto {
    static let iterations = 600_000

    static func randomBytes(_ n: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &b) == errSecSuccess else {
            fatalError("system RNG failure")
        }
        return b
    }

    /// PBKDF2-HMAC-SHA512 (CommonCrypto, FIPS-validated primitive, no third-party code).
    static func derive(_ password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let pw = Array(password.utf8)
        var out = [UInt8](repeating: 0, count: 64)
        let rc = pw.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { cp in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), cp, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                     UInt32(iterations), &out, out.count)
            }
        }
        precondition(rc == kCCSuccess)
        return out
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var d: UInt8 = 0
        for i in 0..<a.count { d |= a[i] ^ b[i] }
        return d == 0
    }

    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    static func sha256(_ s: String) -> String { hex(Array(SHA256.hash(data: Data(s.utf8)))) }
}

enum TOTP {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func base32(_ data: [UInt8]) -> String {
        var out = "", buf = 0, bits = 0
        for byte in data {
            buf = (buf << 8) | Int(byte); bits += 8
            while bits >= 5 { out.append(alphabet[(buf >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(buf << (5 - bits)) & 31]) }
        return out
    }

    static func code(secret: [UInt8], counter: Int64) -> String {
        var c = UInt64(counter).bigEndian
        let msg = withUnsafeBytes(of: &c) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
        let o = Int(mac[19] & 0x0f)
        let n = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o+1]) << 16) | (UInt32(mac[o+2]) << 8) | UInt32(mac[o+3])
        return String(format: "%06d", n % 1_000_000)
    }

    /// Returns the matched counter (for replay prevention) or nil.
    static func verify(secret: [UInt8], input: String, after last: Int64) -> Int64? {
        let now = Int64(Date().timeIntervalSince1970) / 30
        var hit: Int64?
        for c in (now - 1)...(now + 1) {   // always evaluate all three: constant work
            let ok = Crypto.constantTimeEqual(Array(code(secret: secret, counter: c).utf8), Array(input.utf8))
            if ok && c > last { hit = c }
        }
        return hit
    }
}

/// Failed-login throttling: exponential per-IP lockout plus a global circuit breaker.
final class Limiter {
    private struct Rec { var fails = 0; var until = Date.distantPast }
    private var recs: [String: Rec] = [:]
    private var globalFails: [Date] = []
    private var globalUntil = Date.distantPast
    private let lock = NSLock()

    /// Seconds remaining if locked out, else nil.
    func lockout(_ ip: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let r = max(globalUntil, recs[ip]?.until ?? .distantPast).timeIntervalSince(now)
        return r > 0 ? r : nil
    }

    func fail(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var r = recs[ip] ?? Rec()
        r.fails += 1
        if r.fails >= 5 { r.until = now.addingTimeInterval(min(3600, 30 * pow(2, Double(r.fails - 5)))) }
        recs[ip] = r
        globalFails = globalFails.filter { now.timeIntervalSince($0) < 600 } + [now]
        if globalFails.count >= 40 { globalUntil = now.addingTimeInterval(900); globalFails.removeAll()
            log("SECURITY: global login lockout engaged (possible distributed guessing)") }
        if recs.count > 10_000 { recs = recs.filter { $0.value.until > now } }
    }

    func success(_ ip: String) {
        lock.lock(); recs[ip] = nil; lock.unlock()
    }
}

/// In-memory resume tokens so a reconnecting browser never has to re-send the password.
final class TokenStore {
    private struct T { let created: Date; var seen: Date; var live: Bool }
    private var tokens: [String: T] = [:]     // keyed by SHA-256 of the token
    private let lock = NSLock()
    static let absolute: TimeInterval = 12 * 3600
    static let grace: TimeInterval = 15 * 60

    func issue() -> String {
        let tok = Crypto.hex(Crypto.randomBytes(32))
        lock.lock(); defer { lock.unlock() }
        tokens = tokens.filter { valid($0.value) }
        tokens[Crypto.sha256(tok)] = T(created: Date(), seen: Date(), live: true)
        return tok
    }

    private func valid(_ t: T) -> Bool {
        let now = Date()
        return now.timeIntervalSince(t.created) < Self.absolute && (t.live || now.timeIntervalSince(t.seen) < Self.grace)
    }

    func redeem(_ tok: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = Crypto.sha256(tok)
        guard var t = tokens[k], valid(t) else { tokens[k] = nil; return false }
        t.seen = Date(); t.live = true; tokens[k] = t
        return true
    }

    func touch(_ tok: String, live: Bool) {
        lock.lock(); defer { lock.unlock() }
        let k = Crypto.sha256(tok)
        if var t = tokens[k] { t.seen = Date(); t.live = live; tokens[k] = t }
    }

    func revoke(_ tok: String) { lock.lock(); tokens[Crypto.sha256(tok)] = nil; lock.unlock() }
    func revokeAll() { lock.lock(); tokens.removeAll(); lock.unlock() }
}
