import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo

/// H.264 encoder emitting Annex-B access units (what WebCodecs wants with no `description`).
final class H264Encoder {
    private var session: VTCompressionSession?
    private var w = 0, h = 0
    var forceKey = true
    var bpsCap = 22_000_000
    var onFrame: ((Data, Bool, UInt64, String, Int, Int) -> Void)?

    func encode(_ pb: CVPixelBuffer, pts: CMTime) {
        let cw = CVPixelBufferGetWidth(pb), ch = CVPixelBufferGetHeight(pb)
        if session == nil || cw != w || ch != h { rebuild(cw, ch) }
        guard let s = session else { return }
        var props: CFDictionary?
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary; forceKey = false }
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.emit(sb)
        }
    }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    private func rebuild(_ cw: Int, _ ch: Int) {
        invalidate()
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(cw), height: Int32(ch), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &s) == noErr, let s else {
            log("encoder create failed"); return
        }
        let bps = max(2_000_000, min(cw * ch * 4, bpsCap))
        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(s, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10 as CFNumber)   // keyframes are big; we force one on demand
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s; w = cw; h = ch; forceKey = true
    }

    private func emit(_ sb: CMSampleBuffer) {
        guard let bb = CMSampleBufferGetDataBuffer(sb), let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var out = Data()
        var codec = ""
        let start = Data([0, 0, 0, 1])
        if key {
            var nalLen: Int32 = 0
            for i in 0..<2 {
                var p: UnsafePointer<UInt8>?; var n = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                         parameterSetSizeOut: &n, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: &nalLen) == noErr, let p else { return }
                out += start; out += Data(bytes: p, count: n)
                if i == 0 && n >= 4 { codec = String(format: "avc1.%02x%02x%02x", p[1], p[2], p[3]) }
            }
        }
        var total = 0; var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let ptr else { return }
        let raw = UnsafeRawPointer(ptr)
        var o = 0
        while o + 4 <= total {   // AVCC (4-byte lengths) -> Annex B
            let n = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: o, as: UInt32.self)))
            o += 4
            guard n > 0, o + n <= total else { break }
            out += start; out += Data(bytes: raw + o, count: n); o += n
        }
        let pts = UInt64(max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1_000_000))
        onFrame?(out, key, pts, codec, w, h)
    }
}

/// ScreenCaptureKit screen+audio capture. Only runs while an authenticated client is attached.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let q = DispatchQueue(label: "rmm.capture")
    private var stream: SCStream?
    private weak var sink: Conn?
    private var viewW = 1280, viewH = 720
    private var enc: H264Encoder?
    private var lastBuffer: CVPixelBuffer?
    private var gen = 0
    private var dropped = false
    private var lastCodec = ""
    private var quality = 1
    // Quality presets: 0 Sharp, 1 Balanced, 2 Game (smaller desktop + stream, lower bitrate)
    private let desktopCap: [Double] = [3840, 2200, 1500]
    private let streamCap: [Double] = [3840, 2560, 1500]
    private let bitrateCap: [Int] = [22_000_000, 14_000_000, 8_000_000]

    override init() {
        super.init()
        CGDisplayRegisterReconfigurationCallback({ _, flags, ref in
            guard flags.contains(.setModeFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) || flags.contains(.desktopShapeChangedFlag),
                  let ref else { return }
            Unmanaged<Capture>.fromOpaque(ref).takeUnretainedValue().displayChanged()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func attach(_ c: Conn, viewW w: Int, viewH h: Int, cssW: Int, cssH: Int, zoom: Double, quality qi: Int) {
        q.async {
            let qChanged = qi != self.quality
            self.quality = qi
            if qChanged { self.enc?.bpsCap = self.bitrateCap[qi]; self.enc?.invalidate() }
            if !VirtualDisplay.shared.ensure(cssW: cssW, cssH: cssH, zoom: zoom, maxW: self.desktopCap[qi]) { DisplayFit.fit(cssW: cssW, cssH: cssH) }
            let changed = qChanged || self.sink !== c || w != self.viewW || h != self.viewH
            self.sink = c; self.viewW = w; self.viewH = h
            if self.stream == nil { self.start() }
            else if changed { self.reconfigure(); self.enc?.forceKey = true; self.encodeLast() }
            if changed { self.settle() }
        }
    }

    func detach(_ c: Conn) {
        q.async { if self.sink === c { self.sink = nil; self.stop(); VirtualDisplay.shared.teardown(); DisplayFit.restore() } }
    }

    func requestKeyframe() { q.async { self.enc?.forceKey = true; self.encodeLast() } }

    private var reconf = 0
    /// The virtual display takes a moment to change size; re-read it afterwards and resize the stream to match.
    private var settleToken = 0
    private func settle() {
        settleToken += 1; let t = settleToken
        for delay in [0.8, 2.0] {
            q.asyncAfter(deadline: .now() + delay) {
                guard t == self.settleToken, self.sink != nil, self.stream != nil else { return }
                self.reconfigure(); self.enc?.forceKey = true
            }
        }
    }

    private func displayChanged() {
        q.async { self.reconf += 1; let t = self.reconf
        self.q.asyncAfter(deadline: .now() + 1) { if t == self.reconf, self.sink != nil { log("display changed; restarting capture"); self.stop(); self.start() } } }
    }

    private func encodeLast() { if let b = lastBuffer { encode(b, pts: CMClockGetTime(CMClockGetHostTimeClock())) } }

    private func targetSize(displayID: CGDirectDisplayID) -> (Int, Int) {
        var pw = CGDisplayPixelsWide(displayID), ph = CGDisplayPixelsHigh(displayID)
        if let m = CGDisplayCopyDisplayMode(displayID) { pw = m.pixelWidth; ph = m.pixelHeight }
        // Auto-scale to the viewer: never upscale, never exceed 3840 on the long edge.
        let s = min(1.0, Double(viewW) / Double(pw), Double(viewH) / Double(ph), streamCap[quality] / Double(max(pw, ph)))
        func even(_ v: Double) -> Int { max(160, Int(v) & ~1) }
        return (even(Double(pw) * s), even(Double(ph) * s))
    }

    private func makeConfig() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let (w, h) = targetSize(displayID: VirtualDisplay.target)
        c.width = w; c.height = h
        log("capture target \(w)x\(h) (quality \(quality))")
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = false     // the browser draws the cursor locally: zero-lag pointer
        c.queueDepth = 3
        c.capturesAudio = true
        c.sampleRate = 48000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        return c
    }

    private func reconfigure() {
        guard let s = stream else { return }
        Task { try? await s.updateConfiguration(self.makeConfig()) }
    }

    private func start() {
        gen += 1; let g = gen
        let e = H264Encoder()
        e.onFrame = { [weak self] data, key, pts, codec, w, h in self?.send(data, key, pts, codec, w, h) }
        e.bpsCap = bitrateCap[quality]
        enc?.invalidate(); enc = e
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = content.displays.first(where: { $0.displayID == VirtualDisplay.target }) ?? content.displays.first
                else { throw NSError(domain: "rmm", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display"]) }
                let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: self.makeConfig(), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.q)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.q)
                try await s.startCapture()
                self.q.async {
                    if g == self.gen && self.sink != nil { self.stream = s }
                    else { Task { try? await s.stopCapture() } }
                }
            } catch {
                log("capture start failed: \(error.localizedDescription) (is Screen Recording permission granted?)")
                self.q.asyncAfter(deadline: .now() + 3) { if g == self.gen && self.sink != nil { self.start() } }   // auto-recover
            }
        }
    }

    private func stop() {
        gen += 1
        let s = stream; stream = nil
        enc?.invalidate(); enc = nil; lastBuffer = nil; lastCodec = ""
        if let s { Task { try? await s.stopCapture() } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture stopped: \(error.localizedDescription); recovering")
        q.async {
            guard self.stream === stream else { return }
            self.stream = nil
            let g = self.gen
            self.q.asyncAfter(deadline: .now() + 1) { if g == self.gen && self.sink != nil { self.start() } }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let sink else { return }
        switch type {
        case .screen:
            guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let st = arr.first?[.status] as? Int, SCFrameStatus(rawValue: st) == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            lastBuffer = pb
            if sink.videoBacklogged { return }     // pipe is full: drop BEFORE encoding (keeps references valid, keeps latency low)
            encode(pb, pts: CMSampleBufferGetPresentationTimeStamp(sb))
        case .audio:
            guard sink.audioOn, !sink.backlogged else { return }
            sendAudio(sb, sink)
        default: break
        }
    }

    private func encode(_ pb: CVPixelBuffer, pts: CMTime) { enc?.encode(pb, pts: pts) }

    private func send(_ data: Data, _ key: Bool, _ pts: UInt64, _ codec: String, _ w: Int, _ h: Int) {
        guard let sink else { return }
        if key {
            sink.sendJSON(["t": "video", "codec": codec, "w": w, "h": h])
        }
        var pkt = Data([1, key ? 1 : 0])
        withUnsafeBytes(of: sink.nextSeq().bigEndian) { pkt.append(contentsOf: $0) }
        withUnsafeBytes(of: pts.bigEndian) { pkt.append(contentsOf: $0) }
        pkt += data
        sink.sendBinary(pkt)
    }

    private func sendAudio(_ sb: CMSampleBuffer, _ sink: Conn) {
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        try? sb.withAudioBufferList { abl, _ in
            var pcm = [Int16](repeating: 0, count: n * 2)
            func s16(_ f: Float) -> Int16 { Int16(max(-1, min(1, f)) * 32767) }
            if abl.count >= 2 {     // planar float32
                guard let l = abl[0].mData?.assumingMemoryBound(to: Float.self), let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }
                for i in 0..<n { pcm[2*i] = s16(l[i]); pcm[2*i+1] = s16(r[i]) }
            } else if let b = abl.first, let p = b.mData?.assumingMemoryBound(to: Float.self) {
                let ch = Int(b.mNumberChannels)
                for i in 0..<n { pcm[2*i] = s16(p[i*ch]); pcm[2*i+1] = s16(p[i*ch + (ch > 1 ? 1 : 0)]) }
            }
            var pkt = Data([2])
            pcm.withUnsafeBytes { pkt.append(contentsOf: $0) }
            sink.sendBinary(pkt)
        }
    }
}
