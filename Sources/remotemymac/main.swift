import Foundation
import ApplicationServices
import CoreGraphics

setvbuf(stdout, nil, _IOLBF, 0)

func prompt(_ q: String, secret: Bool = false) -> String {
    if secret {
        guard let p = getpass(q) else { return "" }
        return String(cString: p)
    }
    print(q, terminator: ""); return readLine() ?? ""
}

func readNewPassword() -> String {
    while true {
        let a = prompt("New password (min 14 chars, use a long passphrase): ", secret: true)
        if a.count < 14 { print("Too short."); continue }
        if a.utf8.count > 256 { print("Too long (max 256 bytes)."); continue }
        if Set(a).count < 6 { print("Too repetitive."); continue }
        if prompt("Repeat password: ", secret: true) != a { print("Passwords differ."); continue }
        return a
    }
}

func makeHash(_ pw: String) -> (salt: [UInt8], hash: [UInt8]) {
    let salt = Crypto.randomBytes(32)
    return (salt, Crypto.derive(pw, salt: salt, iterations: Crypto.iterations))
}

func printTOTP(_ secret: [UInt8], host: String) {
    let b32 = TOTP.base32(secret)
    print("""

    Two-factor secret (add to Google Authenticator / 1Password / Authy):
      \(b32)
    or open: otpauth://totp/RemoteMyMac:\(host)?secret=\(b32)&issuer=RemoteMyMac&digits=6&period=30

    """)
}

func ensurePermissions(prompt p: Bool) -> Bool {
    var ok = true
    if !CGPreflightScreenCaptureAccess() { ok = false; if p { _ = CGRequestScreenCaptureAccess() } }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: p] as CFDictionary
    if !AXIsProcessTrustedWithOptions(opts) { ok = false }
    return ok
}

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "help" {
case "setup":
    let host = prompt("Public hostname served through Cloudflare (e.g. mac.example.com): ").lowercased()
        .trimmingCharacters(in: .whitespaces)
    guard host.range(of: #"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#, options: .regularExpression) != nil
    else { print("Invalid hostname."); exit(1) }
    let pw = readNewPassword()
    print("Hashing (PBKDF2-HMAC-SHA512, \(Crypto.iterations) rounds)…")
    let (salt, hash) = makeHash(pw)
    let secret = Crypto.randomBytes(20)
    let cfg = Config(hostname: host, port: 8777, salt: salt, hash: hash, iterations: Crypto.iterations, totpSecret: secret)
    do { try cfg.save() } catch { print("Could not save config: \(error)"); exit(1) }
    printTOTP(secret, host: host)
    print("Saved to \(Config.file.path) (mode 600). Next: remotemymac permissions, then remotemymac run")

case "passwd":
    guard var cfg = try? Config.load() else { print("Run setup first."); exit(1) }
    let pw = readNewPassword()
    let (s, h) = makeHash(pw)
    cfg.salt = s; cfg.hash = h; cfg.iterations = Crypto.iterations
    try! cfg.save(); print("Password changed. Restart the service to drop existing sessions.")

case "totp-reset":
    guard var cfg = try? Config.load() else { print("Run setup first."); exit(1) }
    let secret = Crypto.randomBytes(20)
    cfg.totpSecret = secret; cfg.lastTotpCounter = 0
    try! cfg.save(); printTOTP(secret, host: cfg.hostname)

case "totp-off":
    guard var cfg = try? Config.load() else { print("Run setup first."); exit(1) }
    cfg.totpSecret = nil
    try! cfg.save(); print("2FA disabled. Login is password only.")

case "vdtest":
    let ok = VirtualDisplay.shared.ensure(cssW: 1366, cssH: 650, zoom: 1, mirror: false)
    print(ok ? "virtual display id \(VirtualDisplay.shared.id), bounds \(CGDisplayBounds(VirtualDisplay.shared.id))" : "FAILED")
    sleep(2); VirtualDisplay.shared.teardown()

case "permissions":
    if ensurePermissions(prompt: true) { print("Screen Recording and Accessibility are granted.") }
    else { print("Grant Screen Recording and Accessibility to this binary in System Settings > Privacy & Security, then re-run.") }

case "run":
    guard let cfg = try? Config.load() else { print("Run `remotemymac setup` first."); exit(1) }
    if !CGPreflightScreenCaptureAccess() { log("WARNING: Screen Recording NOT granted to this binary") }
    if !AXIsProcessTrusted() {
        log("WARNING: Accessibility NOT granted to this binary; asking macOS to prompt")
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    let server = Server(cfg: cfg)
    do { try server.start() } catch { log("cannot listen: \(error)"); exit(1) }
    log("listening on 127.0.0.1:\(cfg.port) for \(cfg.hostname) (loopback only; expose via Cloudflare Tunnel)")
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }
    dispatchMain()

default:
    print("""
    remotemymac - secure remote control for your Mac via Cloudflare Tunnel (GPL-3.0-or-later)

      setup         choose hostname + password, generate 2FA secret
      permissions   request Screen Recording + Accessibility access
      run           start the server (127.0.0.1 only)
      passwd        change the password
      totp-reset    rotate the 2FA secret
      totp-off      disable 2FA (password only)
    """)
}
