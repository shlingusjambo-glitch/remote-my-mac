// RemoteMyMac - secure remote control for your Mac over a Cloudflare Tunnel.
// Copyright (C) 2026 RemoteMyMac contributors. Licensed under GPL-3.0-or-later.
import Foundation

struct Config: Codable {
    var hostname: String            // public hostname served through Cloudflare, e.g. mac.example.com
    var port: UInt16 = 8777         // loopback-only listen port
    var salt: [UInt8]
    var hash: [UInt8]
    var iterations: Int
    var totpSecret: [UInt8]?
    var lastTotpCounter: Int64 = 0

    static var dir: URL {
        if let o = ProcessInfo.processInfo.environment["RMM_CONFIG_DIR"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RemoteMyMac", isDirectory: true)
    }
    static var file: URL { dir.appendingPathComponent("config.json") }

    static func load() throws -> Config {
        let data = try Data(contentsOf: file)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Config.dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = Config.file.appendingPathExtension("tmp")
        try enc.encode(self).write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(Config.file, withItemAt: tmp)
    }
}

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("[\(f.string(from: Date()))] \(s)\n".utf8))
}
