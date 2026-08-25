//
//  ClipBuffer.swift
//  SahilStatsLite
//
//  PURPOSE: Retroactive highlight capture ("Clip"). Keeps a rolling ring of the
//           last ~30s of ALREADY-COMPOSITED frames (scoreboard burned in) as
//           encoded HEVC, so a tap can save [30s back + N s forward] instantly —
//           with the correct HISTORICAL score, no timeline replay needed.
//
//           A raw 30s 4K ring would be ~30 GB; encoded HEVC @ 8 Mbps is ~30 MB.
//           So we run a lightweight continuous VTCompressionSession (1080p) fed
//           the same composited buffers RecordingManager writes to the game file.
//
//  KEY TYPES: ClipBuffer (@unchecked Sendable), ClipState
//  DEPENDS ON: VideoToolbox, AVFoundation, CoreImage
//  FED BY:    RecordingManager (feedVideo / feedAudio, after overlay render)
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import CoreImage
import CoreMedia

/// Box to carry a non-Sendable AVFoundation/CoreVideo value across a `@Sendable`
/// dispatch closure. These objects are only ever touched on `clipQueue`, so the
/// hand-off is safe even though the types aren't `Sendable`.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// High-level state of the clip subsystem, surfaced to the UI for the HUD.
nonisolated enum ClipState: Equatable, Sendable {
    case idle              // not armed (no live game)
    case buffering         // armed, ring filling — a Clip can be taken
    case clipping(Int)     // exporting; associated value = seconds remaining in forward window
    case saving            // forward window done, finalizing file
    case saved             // just saved (transient; UI shows a toast then returns to buffering)
}

// `nonisolated` opts every member out of the project's MainActor-default isolation:
// this class lives entirely on `clipQueue` and the capture processing queue, never main.
nonisolated final class ClipBuffer: @unchecked Sendable {

    // MARK: - Tunables

    private let backSeconds: Double = 30.0          // retroactive window
    private let clipBitRate: Int = 8_000_000        // 1080p highlight — plenty for sharing
    private let targetLongEdge: CGFloat = 1920      // downscale for the ring (clips don't need 4K)
    private let keyframeIntervalSeconds: Double = 1 // 1s GOP → clean pruning at keyframe boundaries

    // MARK: - Callbacks (set by RecordingManager, invoked on an arbitrary queue)

    /// Fired whenever `state` changes. Hop to main before touching UI.
    var onStateChange: ((ClipState) -> Void)?
    /// Fired with the finished clip file URL (in Documents/Highlights). Handle Photos + store here.
    var onClipSaved: ((URL) -> Void)?

    private(set) var state: ClipState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    // MARK: - Serial queue guarding ALL ring + writer + session state

    private let clipQueue = DispatchQueue(label: "com.sahilstats.clipBuffer", qos: .userInitiated)

    // MARK: - Compression session (created lazily on first frame)

    private var session: VTCompressionSession?
    private var sessionWidth: Int = 0
    private var sessionHeight: Int = 0
    private var armed = false

    // MARK: - Downscale (synchronous, on the caller's queue, into our own pool)

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var scalePool: CVPixelBufferPool?
    private var scaleWidth = 0
    private var scaleHeight = 0

    // MARK: - Ring buffers (encoded video samples + raw audio samples)

    private var videoSamples: [CMSampleBuffer] = []
    private var audioSamples: [CMSampleBuffer] = []

    // MARK: - Export state

    private var exporting = false
    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var exportDeadlinePTS: CMTime = .invalid
    private var lastExportedVideoPTS: CMTime = .invalid
    private var lastExportedAudioPTS: CMTime = .invalid
    private var forwardSeconds: Double = 20
    private var currentClipURL: URL?

    // MARK: - Lifecycle

    /// Begin buffering (call when a live recording starts). Idempotent.
    func arm() {
        clipQueue.async {
            guard !self.armed else { return }
            self.armed = true
            self.state = .buffering
            debugPrint("🎬 ClipBuffer armed")
        }
    }

    /// Stop buffering and tear everything down (call when recording stops).
    func disarm() {
        clipQueue.async {
            self.armed = false
            if self.exporting { self.finishExportLocked(deleteFile: true) }
            self.teardownSessionLocked()
            self.videoSamples.removeAll()
            self.audioSamples.removeAll()
            self.state = .idle
            debugPrint("🎬 ClipBuffer disarmed")
        }
    }

    var isArmed: Bool { armed }

    // MARK: - Frame intake (called from RecordingManager's processing queue)

    /// Feed a composited video frame (overlay already burned in). Downscales
    /// synchronously into our own buffer, then encodes off the caller's thread so
    /// we never hold a capture-pool buffer past return (which would starve capture).
    func feedVideo(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard armed else { return }
        guard let scaled = downscale(pixelBuffer) else { return }
        let boxed = Unchecked(value: scaled)
        clipQueue.async { self.encodeLocked(boxed.value, pts: timestamp) }
    }

    /// Feed a RAW (un-composited) video frame and burn the scoreboard in ourselves.
    /// Used in stats-only mode, where there is no file AVAssetWriter to composite the
    /// overlay — so the clip still gets the (historical) score burned in. Downscales
    /// synchronously; overlay render + encode happen on clipQueue.
    func feedVideoCompositing(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime, overlay: OverlayRenderer) {
        guard armed else { return }
        guard let scaled = downscale(pixelBuffer) else { return }
        let boxed = Unchecked(value: scaled)
        clipQueue.async {
            _ = overlay.render(onto: boxed.value)
            self.encodeLocked(boxed.value, pts: timestamp)
        }
    }

    /// Feed a raw audio sample buffer (from AVCaptureAudioDataOutput).
    func feedAudio(_ sampleBuffer: CMSampleBuffer) {
        guard armed else { return }
        // Box to carry the non-Sendable sample across the async hop (touched only on clipQueue).
        let boxed = Unchecked(value: sampleBuffer)
        clipQueue.async { self.handleAudioLocked(boxed.value) }
    }

    // MARK: - Trigger

    /// Save a clip: the buffered ~30s + `forward` seconds of what happens next.
    func startClip(forwardSeconds forward: Double) {
        clipQueue.async {
            guard self.armed, !self.exporting else { return }
            self.forwardSeconds = max(3, forward)
            self.beginExportLocked()
        }
    }

    /// Cut the forward window short and save immediately.
    func stopClip() {
        clipQueue.async {
            guard self.exporting else { return }
            self.finishExportLocked(deleteFile: false)
        }
    }

    // MARK: - Downscale

    /// Scale the source frame down to <= targetLongEdge on the long edge, preserving
    /// aspect (even dimensions for the encoder), into a buffer from our own pool.
    private func downscale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        guard srcW > 0, srcH > 0 else { return nil }

        let longEdge = CGFloat(max(srcW, srcH))
        let factor = min(1.0, targetLongEdge / longEdge)
        var dstW = Int((CGFloat(srcW) * factor).rounded())
        var dstH = Int((CGFloat(srcH) * factor).rounded())
        dstW -= dstW % 2   // encoder wants even dims
        dstH -= dstH % 2

        if scalePool == nil || dstW != scaleWidth || dstH != scaleHeight {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: dstW,
                kCVPixelBufferHeightKey as String: dstH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            scalePool = pool
            scaleWidth = dstW
            scaleHeight = dstH
        }

        guard let pool = scalePool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard let outBuffer = out else { return nil }

        if factor == 1.0 {
            // Same size — straight copy through CoreImage keeps it simple/correct.
            ciContext.render(CIImage(cvPixelBuffer: src), to: outBuffer)
        } else {
            let img = CIImage(cvPixelBuffer: src)
                .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            ciContext.render(img, to: outBuffer)
        }
        return outBuffer
    }

    // MARK: - Encode (clipQueue)

    private func encodeLocked(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if session == nil {
            createSessionLocked(width: CVPixelBufferGetWidth(pixelBuffer),
                                 height: CVPixelBufferGetHeight(pixelBuffer))
        }
        guard let session = session else { return }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self = self else { return }
            guard status == noErr, let sb = sampleBuffer, CMSampleBufferDataIsReady(sb) else {
                debugPrint("⚠️ ClipBuffer: encode callback bad status \(status)")
                return
            }
            self.clipQueue.async { self.handleEncodedLocked(sb) }
        }
        if status != noErr {
            debugPrint("⚠️ ClipBuffer: EncodeFrame returned \(status)")
        }
    }

    private func createSessionLocked(width: Int, height: Int) {
        var newSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &newSession
        )
        guard status == noErr, let s = newSession else {
            debugPrint("❌ ClipBuffer: failed to create VTCompressionSession (\(status))")
            return
        }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: clipBitRate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: keyframeIntervalSeconds))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: 30))
        VTCompressionSessionPrepareToEncodeFrames(s)

        session = s
        sessionWidth = width
        sessionHeight = height
        debugPrint("🎬 ClipBuffer session ready \(width)x\(height)")
    }

    private func teardownSessionLocked() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    // MARK: - Encoded-sample handling + ring pruning (clipQueue)

    private var encodedCount = 0

    private func handleEncodedLocked(_ sb: CMSampleBuffer) {
        videoSamples.append(sb)
        pruneLocked()

        encodedCount += 1
        if encodedCount % 90 == 0, let first = videoSamples.first, let last = videoSamples.last {
            let span = (CMSampleBufferGetPresentationTimeStamp(last) - CMSampleBufferGetPresentationTimeStamp(first)).seconds
            debugPrint("🎬 ClipBuffer ring: \(videoSamples.count) frames, \(String(format: "%.1f", span))s")
        }

        guard exporting, let input = writerVideoInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        // Skip anything already flushed from the backlog.
        if lastExportedVideoPTS.isValid && pts <= lastExportedVideoPTS { return }
        appendWhenReady(input, sb)
        lastExportedVideoPTS = pts
        publishRemaining(currentPTS: pts)
        if exportDeadlinePTS.isValid && pts >= exportDeadlinePTS {
            finishExportLocked(deleteFile: false)
        }
    }

    private func handleAudioLocked(_ sb: CMSampleBuffer) {
        audioSamples.append(sb)
        pruneAudioLocked()

        guard exporting, let input = writerAudioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if lastExportedAudioPTS.isValid && pts <= lastExportedAudioPTS { return }
        if exportDeadlinePTS.isValid && pts > exportDeadlinePTS { return }
        appendWhenReady(input, sb)
        lastExportedAudioPTS = pts
    }

    /// Drop encoded video older than `backSeconds`, but only whole GOPs, so the
    /// retained buffer always begins at a keyframe (decodable from the start).
    private func pruneLocked() {
        guard let last = videoSamples.last else { return }
        let latest = CMSampleBufferGetPresentationTimeStamp(last)
        let cutoff = latest - CMTime(seconds: backSeconds, preferredTimescale: 600)

        // Find the highest-index keyframe whose PTS <= cutoff; drop everything before it.
        var dropTo = 0
        for (i, sb) in videoSamples.enumerated() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if pts <= cutoff && isKeyframe(sb) {
                dropTo = i
            } else if pts > cutoff {
                break
            }
        }
        if dropTo > 0 { videoSamples.removeFirst(dropTo) }
    }

    /// Keep audio no older than the oldest retained video sample.
    private func pruneAudioLocked() {
        guard let firstVideo = videoSamples.first else { return }
        let floorPTS = CMSampleBufferGetPresentationTimeStamp(firstVideo)
        while let a = audioSamples.first,
              CMSampleBufferGetPresentationTimeStamp(a) < floorPTS {
            audioSamples.removeFirst()
        }
    }

    private func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[CFString: Any]], let first = atts.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool { return !notSync }
        return true  // absence of NotSync means it IS a sync sample
    }

    // MARK: - Export (clipQueue)

    private func beginExportLocked() {
        // Need at least one keyframe to start decoding.
        guard let firstVideoFormat = videoSamples.first(where: { CMSampleBufferGetFormatDescription($0) != nil })
                .flatMap({ CMSampleBufferGetFormatDescription($0) }),
              let startSample = videoSamples.first else {
            debugPrint("⚠️ ClipBuffer: startClip with empty buffer — ignoring")
            return
        }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Highlights", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = dir.appendingPathComponent("clip_\(df.string(from: Date())).mov")
        try? FileManager.default.removeItem(at: url)

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)

            // Passthrough video (samples are already HEVC).
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: firstVideoFormat)
            vInput.expectsMediaDataInRealTime = true
            if w.canAdd(vInput) { w.add(vInput) }

            // AAC audio, matching the source sample rate / channel count when available.
            var aInput: AVAssetWriterInput?
            if let firstAudio = audioSamples.first,
               let asbd = audioASBD(firstAudio) {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.mSampleRate,
                    AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                    AVEncoderBitRateKey: 96_000
                ]
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                ai.expectsMediaDataInRealTime = true
                if w.canAdd(ai) { w.add(ai); aInput = ai }
            }

            let startPTS = CMSampleBufferGetPresentationTimeStamp(startSample)
            guard w.startWriting() else {
                debugPrint("❌ ClipBuffer: startWriting failed: \(String(describing: w.error))")
                return
            }
            w.startSession(atSourceTime: startPTS)

            writer = w
            writerVideoInput = vInput
            writerAudioInput = aInput
            currentClipURL = url
            exporting = true

            // Flush the backlog.
            for sb in videoSamples {
                appendWhenReady(vInput, sb)
                lastExportedVideoPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            }
            if let ai = aInput {
                for sb in audioSamples {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if pts < startPTS { continue }
                    appendWhenReady(ai, sb)
                    lastExportedAudioPTS = pts
                }
            }

            exportDeadlinePTS = lastExportedVideoPTS + CMTime(seconds: forwardSeconds, preferredTimescale: 600)
            state = .clipping(Int(forwardSeconds.rounded()))
            debugPrint("🎬 ClipBuffer exporting: backlog \(videoSamples.count) frames, forward \(forwardSeconds)s → \(url.lastPathComponent)")
        } catch {
            debugPrint("❌ ClipBuffer: failed to create writer: \(error)")
        }
    }

    private func finishExportLocked(deleteFile: Bool) {
        guard exporting else { return }
        exporting = false
        exportDeadlinePTS = .invalid
        lastExportedVideoPTS = .invalid
        lastExportedAudioPTS = .invalid

        let w = writer
        let url = currentClipURL
        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        currentClipURL = nil

        guard let writer = w, let url = url else {
            state = armed ? .buffering : .idle
            return
        }

        if deleteFile {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            state = armed ? .buffering : .idle
            return
        }

        state = .saving
        let boxedWriter = Unchecked(value: writer)
        writer.finishWriting { [weak self] in
            guard let self = self else { return }
            self.clipQueue.async {
                let writer = boxedWriter.value
                if writer.status == .completed {
                    debugPrint("🎬 Clip saved: \(url.lastPathComponent)")
                    self.onClipSaved?(url)
                    self.state = .saved
                    // Return to buffering shortly so the HUD toast can clear.
                    self.clipQueue.asyncAfter(deadline: .now() + 2.0) {
                        if self.armed && !self.exporting { self.state = .buffering }
                    }
                } else {
                    debugPrint("❌ Clip finishWriting failed: \(String(describing: writer.error))")
                    try? FileManager.default.removeItem(at: url)
                    self.state = self.armed ? .buffering : .idle
                }
            }
        }
    }

    // MARK: - Helpers

    /// Append a sample, briefly spin-waiting for the input to be ready. Backlog flush
    /// happens on our own background serial queue, so a short spin is acceptable.
    private func appendWhenReady(_ input: AVAssetWriterInput, _ sb: CMSampleBuffer) {
        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 200 {
            usleep(2000)  // 2ms
            spins += 1
        }
        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sb) {
            debugPrint("⚠️ ClipBuffer: append failed, writer status \(writer?.status.rawValue ?? -1)")
        }
    }

    private func audioASBD(_ sb: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let ptr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        return ptr.pointee
    }

    private func publishRemaining(currentPTS: CMTime) {
        guard exportDeadlinePTS.isValid else { return }
        let remaining = (exportDeadlinePTS - currentPTS).seconds
        if case .clipping = state {
            state = .clipping(max(0, Int(remaining.rounded(.up))))
        }
    }
}
