//
//  RecordingManager.swift
//  SahilStatsLite
//
//  PURPOSE: AVFoundation video capture with real-time scoreboard overlay.
//           Records 4K video via AVAssetWriter, renders overlay per-frame,
//           provides AI frame callback for Skynet processing at SD resolution.
//           Camera session starts during warmup; file recording starts on clock.
//  KEY TYPES: RecordingManager (singleton, @MainActor)
//  DEPENDS ON: OverlayRenderer
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
@preconcurrency import AVFoundation
import AVKit  // Required for Camera Control overlay UI (iOS 18+)
import UIKit
import Photos
import Combine

class RecordingManager: NSObject, ObservableObject {
    static let shared = RecordingManager()

    // MARK: - Published Properties

    @MainActor @Published var isRecording: Bool = false
    @MainActor @Published var recordingDuration: TimeInterval = 0
    @MainActor @Published var error: String?
    @MainActor @Published var isSessionReady: Bool = false
    @MainActor @Published var permissionGranted: Bool = false
    @MainActor @Published var isSimulator: Bool = false
    @MainActor @Published var currentZoomLevel: CGFloat = 1.0  // Updated by Camera Control button

    // MARK: - Camera Control (iPhone 16+)

    /// Callback when zoom changes from Camera Control button (for UI sync)
    var onZoomChanged: ((CGFloat) -> Void)?
    private let cameraControlQueue = DispatchQueue(label: "com.sahilstats.cameraControl")

    // MARK: - AI Frame Callback (for Skynet mode)

    /// Optional callback for AI processing of video frames
    /// Called on background queue - do NOT update UI directly
    nonisolated(unsafe) var onFrameForAI: ((_ pixelBuffer: CVPixelBuffer) -> Void)?

    /// Streaming flag — checked per-frame to avoid Task overhead when not streaming
    nonisolated(unsafe) var isStreamingActive: Bool = false
    private nonisolated(unsafe) var lastAIFrameTime: CFAbsoluteTime = 0
    private let aiFrameInterval: CFAbsoluteTime = 0.067  // 15 FPS for AI processing

    // MARK: - Capture Session

    @MainActor private(set) var captureSession: AVCaptureSession?
    private nonisolated(unsafe) var videoDataOutput: AVCaptureVideoDataOutput?
    private nonisolated(unsafe) var audioDataOutput: AVCaptureAudioDataOutput?
    private var currentVideoDevice: AVCaptureDevice?
    
    // MARK: - AI Downscaler (Low-Res AI, High-Res Record)
    
    private nonisolated(unsafe) var aiContext = CIContext(options: [.useSoftwareRenderer: false])
    private nonisolated(unsafe) var aiPixelBufferPool: CVPixelBufferPool?
    private let aiTargetWidth = 640
    private let aiTargetHeight = 360

    // MARK: - Asset Writer (for recording with overlay - accessed from processing queue)

    private nonisolated(unsafe) var assetWriter: AVAssetWriter?
    private nonisolated(unsafe) var videoWriterInput: AVAssetWriterInput?
    private nonisolated(unsafe) var audioWriterInput: AVAssetWriterInput?
    private nonisolated(unsafe) var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?

    // MARK: - Recording State (accessed from processing queue - not MainActor)

    private nonisolated(unsafe) var isWritingStarted = false
    private nonisolated(unsafe) var recordingStartTime: CMTime?
    private nonisolated(unsafe) var currentRecordingURL: URL?
    private nonisolated(unsafe) var isWriterConfigured = false
    private nonisolated(unsafe) var pendingOutputURL: URL?
    private nonisolated(unsafe) var frameCount: Int = 0
    private var recordingTimer: Timer?
    private let processingQueue = DispatchQueue(label: "com.sahilstats.videoProcessing", qos: .userInitiated)

    // MARK: - Overlay Renderer

    let overlayRenderer = OverlayRenderer()

    // MARK: - Clip (retroactive highlight) buffer

    let clipBuffer = ClipBuffer()
    @MainActor @Published var clipState: ClipState = .idle

    /// The current game's id, stamped onto saved clips so the Store can group clips
    /// from one session together — even if the game itself is never saved.
    nonisolated(unsafe) var currentClipGameId: String?

    /// Practice mode: clips are tagged "Practice" (no score/opponent) and grouped
    /// separately in the Store.
    nonisolated(unsafe) var isPracticeSession = false

    /// Whether the clip ring should burn the scoreboard overlay in. True for stats-only
    /// games; false for practice (no score to show).
    nonisolated(unsafe) var compositeClipOverlay = true

    // MARK: - Completion Handler

    private var recordingFinishedContinuation: CheckedContinuation<URL?, Never>?
    @MainActor @Published var isFileReady: Bool = false

    // MARK: - Initialization

    private override init() {
        super.init()

        // Surface clip state to the UI, and handle a finished clip (Photos + store).
        clipBuffer.onStateChange = { [weak self] st in
            Task { @MainActor in self?.clipState = st }
        }
        clipBuffer.onClipSaved = { [weak self] url in
            self?.handleClipSaved(url)
        }
    }

    // MARK: - Clip control

    /// Save a retroactive highlight: buffered ~30s + forward window from Settings.
    @MainActor
    func triggerClip() {
        guard clipBuffer.isArmed else {
            debugPrint("🎬 triggerClip ignored — clip buffer not armed")
            return
        }
        let forward = UserDefaults.standard.object(forKey: "clipForwardLength") as? Int ?? 20
        clipBuffer.startClip(forwardSeconds: Double(forward))
    }

    /// Cut the forward window short and save now.
    @MainActor
    func stopClip() {
        clipBuffer.stopClip()
    }

    /// Stats-only mode: arm the clip ring without recording the whole game to a file.
    /// (The capture session must already be set up via requestPermissionsAndSetup.)
    @MainActor
    func startClipBuffering() {
        clipBuffer.arm()
    }

    /// Stop stats-only clip buffering (leaving the view).
    @MainActor
    func stopClipBuffering() {
        clipBuffer.disarm()
    }

    /// Called (off-main) when a clip file is finalized: save to Photos + record it.
    nonisolated private func handleClipSaved(_ url: URL) {
        let s = overlayRenderer.state
        let gameId = currentClipGameId
        let practice = isPracticeSession
        Task { @MainActor in
            if practice {
                HighlightStore.shared.add(
                    fileURL: url, gameId: gameId,
                    homeTeam: "Practice", awayTeam: "",
                    homeScore: 0, awayScore: 0,
                    period: "", clockTime: "", isPractice: true
                )
            } else {
                HighlightStore.shared.add(
                    fileURL: url, gameId: gameId,
                    homeTeam: s.homeTeam, awayTeam: s.awayTeam,
                    homeScore: s.homeScore, awayScore: s.awayScore,
                    period: s.period, clockTime: s.clockTime
                )
            }
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if let error = error { debugPrint("❌ Clip → Photos failed: \(error)") }
            }
        }
    }

    /// Reset the recording manager state for a new game
    @MainActor
    func reset() {
        debugPrint("📹 RecordingManager reset")
        isRecording = false
        recordingDuration = 0
        error = nil
        isFileReady = false
        currentRecordingURL = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingFinishedContinuation = nil
        isWritingStarted = false
        isWriterConfigured = false
        recordingStartTime = nil
        pendingOutputURL = nil
        clipBuffer.disarm()

        // Ensure screen auto-lock is re-enabled
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Stop the capture session (call when leaving recording)
    @MainActor
    func stopSession() {
        debugPrint("📹 Stopping capture session")
        captureSession?.stopRunning()

        // Clear all session-related state for clean restart
        captureSession = nil
        videoDataOutput = nil
        audioDataOutput = nil
        currentVideoDevice = nil
        isSessionReady = false
    }

    // MARK: - Permissions

    @MainActor
    func requestPermissionsAndSetup() async {
        // Check camera permission
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch cameraStatus {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            permissionGranted = await AVCaptureDevice.requestAccess(for: .video)
        default:
            permissionGranted = false
            error = "Camera access denied. Please enable in Settings."
            return
        }

        // Also request microphone
        let audioStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if audioStatus == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        
        // Configure global audio session for video recording
        configureAudioSession()

        if permissionGranted {
            await setupCaptureSession()
        }
    }
    
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord allows simultaneous recording and system sounds (if needed)
            // .defaultToSpeaker ensures audio playback goes to speaker, not receiver
            // We REMOVE .allowBluetooth to prevent accidentally recording via low-quality HFP headset
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
            try session.setMode(.videoRecording)
            try session.setActive(true)
            debugPrint("🎙️ AVAudioSession configured for Video Recording")
        } catch {
            debugPrint("⚠️ Failed to configure AVAudioSession: \(error)")
        }
    }

    // MARK: - Setup

    @MainActor
    private func setupCaptureSession() async {
        debugPrint("📹 Setting up capture session...")

        // Check if running on simulator
        #if targetEnvironment(simulator)
        debugPrint("⚠️ Running on SIMULATOR - camera not available!")
        isSimulator = true
        error = "Camera recording requires a physical device. The simulator doesn't have camera access."
        isSessionReady = true  // Set ready so UI can show message
        return
        #else

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Set quality - 4K for recording (AI will downscale its own path)
        if session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
            debugPrint("📹 Using 4K (2160p) preset")
        } else if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            debugPrint("📹 Using 1080p preset fallback")
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            debugPrint("📹 Using 720p preset")
        }

        // Add video input (back camera).
        // NOTE: .builtInWideAngleCamera is Apple's MAIN 1× lens (misleading name).
        // .builtInUltraWideCamera is the actual 0.5× / ~120° wide lens — used for the
        // fixed-tripod full-court capture mode. It cannot be reached by zooming the
        // main camera below 1× (impossible); it's a separate AVCaptureDevice.
        //
        // Log everything the device exposes so the ultrawide is visibly available.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInDualWideCamera, .builtInTripleCamera],
            mediaType: .video,
            position: .back
        )
        for d in discovery.devices {
            debugPrint("📹 available back camera: \(d.localizedName) — \(d.deviceType.rawValue)")
        }

        // Toggle: Settings-backed flag. When ON, prefer the ultrawide lens (full-court
        // capture from an elevated fixed tripod). Falls back to the main lens if the
        // ultrawide is unavailable on the device.
        let preferUltraWide = UserDefaults.standard.bool(forKey: "useUltraWideCamera")
        let ultraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        let mainWide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)

        if let videoDevice = (preferUltraWide ? (ultraWide ?? mainWide) : mainWide) {
            currentVideoDevice = videoDevice
            let isUW = videoDevice.deviceType == .builtInUltraWideCamera
            debugPrint("📹 Using \(isUW ? "ULTRA-WIDE (0.5×)" : "main (1×)") camera: \(videoDevice.localizedName)")

            do {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(videoInput) {
                    session.addInput(videoInput)
                    debugPrint("📹 Added video input")
                }

                // Reset zoom to the lens's native widest (1.0× = the full sensor for
                // whichever lens is active; on the ultrawide that IS the ~120° view).
                try videoDevice.lockForConfiguration()
                videoDevice.videoZoomFactor = 1.0
                videoDevice.unlockForConfiguration()
                debugPrint("📹 Zoom reset to 1.0x (\(isUW ? "ultra-wide native" : "main native"))")
            } catch {
                debugPrint("❌ Failed to create video input: \(error)")
                self.error = "Failed to setup camera: \(error.localizedDescription)"
                return
            }
        }

        // Add audio input
        // Standard setup: iOS automatically selects the microphone matching the active camera
        // (Back Camera -> Back Mic). We rely on this default behavior for stability.
        if let audioDevice = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    debugPrint("📹 Added audio input")
                }
            } catch {
                debugPrint("⚠️ Failed to setup audio: \(error.localizedDescription)")
            }
        }

        // Add video data output (for frame-by-frame processing)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoDataOutput = videoOutput
            debugPrint("📹 Added video data output")
            // Video rotation is configured when recording starts based on device orientation
        }

        // Add audio data output
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: processingQueue)

        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioDataOutput = audioOutput
            debugPrint("📹 Added audio data output")
        }

        // Setup Camera Control button (iPhone 16+ with iOS 18+)
        // MUST be done inside configuration block for native overlay to appear
        setupCameraControl(session: session, device: currentVideoDevice)

        session.commitConfiguration()
        captureSession = session

        // Start session on background thread
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                session.startRunning()
                debugPrint("📹 Capture session started, isRunning: \(session.isRunning)")

                Thread.sleep(forTimeInterval: 0.3)

                DispatchQueue.main.async {
                    self?.isSessionReady = true
                    continuation.resume()
                }
            }
        }
        #endif
    }

    /// Configure video rotation based on current device orientation
    /// Call this when recording starts to capture the correct orientation
    private func configureVideoRotationForRecording() {
        guard let videoOutput = videoDataOutput,
              let connection = videoOutput.connection(with: .video) else {
            debugPrint("⚠️ No video connection to configure rotation")
            return
        }

        let deviceOrientation = UIDevice.current.orientation
        let rotationAngle: CGFloat

        // Determine rotation based on how device is held
        // Swapped values to fix upside-down video
        switch deviceOrientation {
        case .landscapeLeft:
            // Device held with volume buttons down, home button on left
            rotationAngle = 0
        case .landscapeRight:
            // Device held with volume buttons up, home button on right
            rotationAngle = 180
        default:
            // Use interface orientation as fallback for landscape detection
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let interfaceOrientation = windowScene.effectiveGeometry.interfaceOrientation
                switch interfaceOrientation {
                case .landscapeLeft:
                    rotationAngle = 180
                case .landscapeRight:
                    rotationAngle = 0
                default:
                    rotationAngle = 180  // Default
                }
            } else {
                rotationAngle = 180
            }
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
            debugPrint("📹 Set video rotation to \(rotationAngle)° for device orientation: \(deviceOrientation.rawValue)")
        } else {
            debugPrint("⚠️ Rotation angle \(rotationAngle)° not supported")
        }
    }

    // MARK: - Recording Control

    @MainActor
    func startRecording() {
        debugPrint("📹 startRecording() called")

        #if targetEnvironment(simulator)
        debugPrint("⚠️ Cannot record on simulator")
        return
        #else
        
        guard !isRecording else {
            debugPrint("⚠️ Already recording")
            return
        }

        // Create output URL - but don't setup writer yet (wait for first frame to get dimensions)
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "game_\(dateFormatter.string(from: Date())).mov"
        let outputURL = documentsPath.appendingPathComponent(fileName)

        // Delete if exists
        try? FileManager.default.removeItem(at: outputURL)

        // Configure video rotation FIRST (before enabling frame capture)
        // This ensures buffered frames have correct orientation
        configureVideoRotationForRecording()
        
        // Configure audio session for recording
        configureAudioSession()

        // Now store URL to enable frame capture
        pendingOutputURL = outputURL
        currentRecordingURL = outputURL
        isWriterConfigured = false

        isRecording = true
        isWritingStarted = false
        recordingStartTime = nil
        frameCount = 0

        // Arm the retroactive-clip ring buffer for the whole live recording.
        clipBuffer.arm()

        // CRITICAL: Keep screen on during recording to prevent interruption
        UIApplication.shared.isIdleTimerDisabled = true
        debugPrint("📹 Screen auto-lock DISABLED for recording")
        debugPrint("📹 startRecording COMPLETE. pendingOutputURL: \(outputURL.path)")

        // Start duration timer
        let startTime = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }

        debugPrint("📹 Recording started (waiting for first frame): \(outputURL.lastPathComponent)")
        #endif
    }

    /// Setup asset writer with actual frame dimensions (called lazily on first frame)
    private nonisolated func setupAssetWriter(outputURL: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        debugPrint("📹 Setting up asset writer with dimensions: \(width)x\(height)")

        // Video settings - HEVC (H.265) at 15 Mbps.
        // iPhone 16 Pro Max encodes HEVC natively on the Neural Engine.
        // Same perceptual quality as H.264 at ~40% smaller file size —
        // a 32-minute game goes from ~9 GB → ~5.5 GB.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 15_000_000   // 15 Mbps
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        // No transform needed - frames come in landscape orientation via videoRotationAngle = 0
        // The overlay is drawn at the bottom of the landscape frame

        // Pixel buffer adaptor for efficient writing
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        if writer.canAdd(videoInput) {
            writer.add(videoInput)
        }

        // Audio settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000
        ]

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        if writer.canAdd(audioInput) {
            writer.add(audioInput)
        }

        assetWriter = writer
        videoWriterInput = videoInput
        audioWriterInput = audioInput
        pixelBufferAdaptor = adaptor

        debugPrint("📹 Asset writer configured for \(width)x\(height)")
    }

    @MainActor
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        clipBuffer.disarm()

        // Re-enable screen auto-lock
        UIApplication.shared.isIdleTimerDisabled = false
        debugPrint("📹 Screen auto-lock RE-ENABLED")

        finishWriting()
    }

    @MainActor
    func stopRecordingAndWait() async -> URL? {
        guard isRecording else {
            return nil
        }
        
        // If writer was never configured (e.g. no frames received), no file exists
        if !isWriterConfigured {
            debugPrint("⚠️ Stop called but writer not configured - no frames captured")
            isRecording = false
            recordingTimer?.invalidate()
            recordingTimer = nil
            clipBuffer.disarm()
            UIApplication.shared.isIdleTimerDisabled = false
            return nil
        }

        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        clipBuffer.disarm()

        // Re-enable screen auto-lock
        UIApplication.shared.isIdleTimerDisabled = false
        debugPrint("📹 Screen auto-lock RE-ENABLED")

        return await withCheckedContinuation { continuation in
            self.recordingFinishedContinuation = continuation
            finishWriting()
        }
    }

    private func finishWriting() {
        processingQueue.async { [weak self] in
            guard let self = self, let writer = self.assetWriter else {
                self?.resumeFinishedContinuation(with: nil)
                return
            }

            self.videoWriterInput?.markAsFinished()
            self.audioWriterInput?.markAsFinished()

            writer.finishWriting {
                let url = self.currentRecordingURL
                debugPrint("📹 Recording finished: \(url?.lastPathComponent ?? "nil"), total frames: \(self.frameCount)")

                Task { @MainActor in
                    self.isFileReady = true
                }

                self.resumeFinishedContinuation(with: url)

                // Cleanup
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.pixelBufferAdaptor = nil
                self.isWriterConfigured = false
                self.pendingOutputURL = nil
            }
        }
    }

    private func resumeFinishedContinuation(with url: URL?) {
        DispatchQueue.main.async { [weak self] in
            self?.recordingFinishedContinuation?.resume(returning: url)
            self?.recordingFinishedContinuation = nil
        }
    }

    func getRecordingURL() -> URL? {
        return currentRecordingURL
    }

    // MARK: - Overlay State Updates

    func updateOverlay(homeTeam: String, awayTeam: String, homeScore: Int, awayScore: Int, period: String, clockTime: String, isClockRunning: Bool = true, eventName: String = "") {
        // Single atomic assignment: processing queue reads a consistent snapshot
        overlayRenderer.state = OverlayState(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            homeScore: homeScore,
            awayScore: awayScore,
            period: period,
            clockTime: clockTime,
            isClockRunning: isClockRunning,
            eventName: eventName
        )
    }

    // MARK: - Camera Control

    func setZoom(factor: CGFloat) -> CGFloat {
        guard let device = currentVideoDevice else { return 1.0 }

        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 6.0)
            let clampedFactor = max(1.0, min(factor, maxZoom))
            device.videoZoomFactor = clampedFactor
            device.unlockForConfiguration()
            return clampedFactor
        } catch {
            return device.videoZoomFactor
        }
    }

    func getCurrentZoom() -> CGFloat {
        return currentVideoDevice?.videoZoomFactor ?? 1.0
    }

    // MARK: - Camera Control Button (iPhone 16+)

    /// Setup the physical Camera Control button for zoom (iOS 18+, iPhone 16+)
    @MainActor
    private func setupCameraControl(session: AVCaptureSession, device: AVCaptureDevice?) {
        guard let device = device else {
            debugPrint("📹 No camera device for Camera Control setup")
            return
        }

        // Check if Camera Control is available (iOS 18+)
        if #available(iOS 18.0, *) {
            guard session.supportsControls else {
                debugPrint("📹 Camera Controls not supported on this device")
                return
            }

            // Remove any existing controls
            for control in session.controls {
                session.removeControl(control)
            }

            // Create zoom slider control
            let zoomSlider = AVCaptureSystemZoomSlider(device: device) { [weak self] zoomFactor in
                // This callback runs on cameraControlQueue
                DispatchQueue.main.async {
                    self?.currentZoomLevel = zoomFactor
                    self?.onZoomChanged?(zoomFactor)
                }
            }

            // Add the zoom control to the session
            if session.canAddControl(zoomSlider) {
                session.addControl(zoomSlider)
                debugPrint("📹 ✅ Camera Control zoom slider added (iPhone 16 Camera Control button)")
            } else {
                debugPrint("📹 Cannot add Camera Control zoom slider")
            }

            // Set delegate for control events
            session.setControlsDelegate(self, queue: cameraControlQueue)
            debugPrint("📹 Camera Control delegate set")
        } else {
            debugPrint("📹 Camera Control requires iOS 18+ (current: \(UIDevice.current.systemVersion))")
        }
    }

    // MARK: - Save to Photos

    func saveToPhotoLibrary() async -> Bool {
        guard let url = currentRecordingURL else { return false }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(returning: false)
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } completionHandler: { success, error in
                    if let error = error {
                        debugPrint("❌ Failed to save to photos: \(error)")
                    }
                    continuation.resume(returning: success)
                }
            }
        }
    }
}

// MARK: - Sample Buffer Delegate

extension RecordingManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Handle video frames for AI processing (even when not recording)
        if output === videoDataOutput, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            
            let now = CFAbsoluteTimeGetCurrent()
            if let callback = onFrameForAI, now - lastAIFrameTime >= aiFrameInterval {
                lastAIFrameTime = now
                
                // Downscale for Vision (640x360)
                if let lowResBuffer = downscaleForAI(pixelBuffer) {
                    callback(lowResBuffer)
                } else {
                    // Fallback to full res if downscale fails
                    callback(pixelBuffer)
                }
            }
        }

        // Stats-only clip buffering: no file writer is running, but the clip ring is
        // armed — feed it directly (compositing the scoreboard ourselves) so a Clip
        // can be saved even when the full game isn't being recorded to a file.
        if clipBuffer.isArmed && pendingOutputURL == nil && assetWriter == nil {
            if output === videoDataOutput, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if compositeClipOverlay {
                    clipBuffer.feedVideoCompositing(pb, timestamp: ts, overlay: overlayRenderer)
                } else {
                    clipBuffer.feedVideo(pb, timestamp: ts)  // practice: clean, no scoreboard
                }
            } else if output === audioDataOutput {
                clipBuffer.feedAudio(sampleBuffer)
            }
        }

        // Only process for recording if we're supposed to be recording
        guard pendingOutputURL != nil || assetWriter != nil else { return }

        // Get presentation timestamp
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Handle video frames
        if output === videoDataOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                debugPrint("⚠️ Frame received but no pixel buffer")
                return 
            }

            // Lazily setup asset writer on first video frame to get actual dimensions
            if !isWriterConfigured {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)

                guard let outputURL = pendingOutputURL else { 
                    debugPrint("⚠️ Frame received but pendingOutputURL is nil")
                    return 
                }

                // Log frame info for debugging
                let isLandscape = width > height
                debugPrint("📹 First frame received: \(width)x\(height) (landscape: \(isLandscape)) at \(timestamp.seconds)s")

                do {
                    try setupAssetWriter(outputURL: outputURL, width: width, height: height)
                    isWriterConfigured = true
                    debugPrint("📹 Asset writer configured: \(width)x\(height)")
                } catch {
                    debugPrint("❌ Failed to setup asset writer: \(error)")
                    return
                }
            }

            guard let writer = assetWriter else { return }

            // Start writing session on first frame
            if !isWritingStarted {
                if writer.status == .unknown {
                    writer.startWriting()
                    writer.startSession(atSourceTime: timestamp)
                    recordingStartTime = timestamp
                    isWritingStarted = true
                    debugPrint("📹 Asset writer started at \(timestamp.seconds)s")
                }
            }

            guard writer.status == .writing else { return }

            processVideoFrame(pixelBuffer, timestamp: timestamp)
        }

        // Handle audio frames
        if output === audioDataOutput {
            guard let writer = assetWriter, writer.status == .writing else { return }
            processAudioFrame(sampleBuffer)
        }
    }

    nonisolated private func downscaleForAI(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = CGFloat(aiTargetWidth) / CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let scaleY = CGFloat(aiTargetHeight) / CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        let resized = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // Setup pool lazily
        if aiPixelBufferPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: aiTargetWidth,
                kCVPixelBufferHeightKey as String: aiTargetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &aiPixelBufferPool)
        }
        
        var outputBuffer: CVPixelBuffer?
        if let pool = aiPixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        }
        
        if let output = outputBuffer {
            aiContext.render(resized, to: output)
            return output
        }
        
        return nil
    }

    nonisolated private func processVideoFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard let videoInput = videoWriterInput else {
            debugPrint("⚠️ No video input available")
            return
        }

        guard videoInput.isReadyForMoreMediaData else {
            // Writer is busy, skip this frame (normal under load)
            return
        }

        // Apply overlay to the frame — scoreboard burned in once here
        _ = overlayRenderer.render(onto: pixelBuffer)

        // Fork composited frame to the retroactive clip ring (downscales + copies
        // synchronously, so the capture buffer is never held past return).
        clipBuffer.feedVideo(pixelBuffer, timestamp: timestamp)

        // Fork composited frame to live stream if active (same frame, no extra render)
        if isStreamingActive {
            StreamingService.shared.appendVideoBuffer(pixelBuffer, timestamp: timestamp)
        }

        // Write the composited frame to local file
        guard let adaptor = pixelBufferAdaptor else {
            debugPrint("⚠️ No pixel buffer adaptor")
            return
        }

        let success = adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        if success {
            frameCount += 1
            // Log every 60 frames (~2 seconds at 30fps)
            if frameCount % 60 == 0 {
                debugPrint("📹 Processed \(frameCount) frames")
            }
        } else {
            debugPrint("❌ Failed to append frame at \(timestamp.seconds)s, writer status: \(assetWriter?.status.rawValue ?? -1)")
            if let error = assetWriter?.error {
                debugPrint("❌ Writer error: \(error)")
            }
        }
    }

    nonisolated private func processAudioFrame(_ sampleBuffer: CMSampleBuffer) {
        // Fork audio to the retroactive clip ring.
        clipBuffer.feedAudio(sampleBuffer)

        // Fork audio to live stream
        if isStreamingActive {
            StreamingService.shared.appendAudioBuffer(sampleBuffer)
        }
        guard let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }
}

// MARK: - Camera Control Delegate (iOS 18+, iPhone 16+)

@available(iOS 18.0, *)
extension RecordingManager: AVCaptureSessionControlsDelegate {
    nonisolated func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        debugPrint("📹 Camera Control became active")
    }

    nonisolated func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        debugPrint("📹 Camera Control entering fullscreen")
    }

    nonisolated func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        debugPrint("📹 Camera Control exiting fullscreen")
    }

    nonisolated func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        debugPrint("📹 Camera Control became inactive")
    }
}
