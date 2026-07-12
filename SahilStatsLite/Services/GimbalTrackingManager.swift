//
//  GimbalTrackingManager.swift
//  SahilStatsLite
//
//  PURPOSE: DockKit gimbal integration for Insta360 Flow Pro 2. Controls
//           physical pan/tilt as a 2-axis stabilizer guided by Skynet.
//           DockKit system tracking AI is DISABLED. Skynet is the sole tracking brain.
//           Skynet calls updateTrackingROI(center:) each frame to steer the physical gimbal.
//  KEY TYPES: GimbalTrackingManager (singleton), GimbalMode (off/stabilize/track)
//  DEPENDS ON: DockKit (iOS 18+), AVFoundation
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import AVFoundation
import Combine
import CoreMotion
import SwiftUI
import Spatial
#if canImport(DockKit)
import DockKit
#endif

// MARK: - Gimbal Mode

enum GimbalMode: String, CaseIterable {
    case off = "Off"
    case stabilize = "Stabilize"
    case track = "Auto-Track"

    var icon: String {
        switch self {
        case .off: return "iphone"
        case .stabilize: return "gyroscope"
        case .track: return "person.fill.viewfinder"
        }
    }

    var description: String {
        switch self {
        case .off: return "Handheld, no gimbal"
        case .stabilize: return "Gimbal smoothing, manual aim"
        case .track: return "Auto-follow subjects"
        }
    }
}

@MainActor
final class GimbalTrackingManager: ObservableObject {
    static let shared = GimbalTrackingManager()

    // MARK: - Published Properties

    @Published var gimbalMode: GimbalMode = .track
    @Published var isTrackingActive: Bool = false
    @Published var isDockKitAvailable: Bool = false
    @Published var lastError: String?
    @Published var trackedSubjectCount: Int = 0

    // MARK: - DockKit Properties

    #if canImport(DockKit)
    @available(iOS 18.0, *)
    private var dockAccessory: DockAccessory?
    #endif

    private var trackingTask: Task<Void, Never>?
    private var roiUpdateTask: Task<Void, Never>?

    // MARK: - PID Controller State (pan + tilt)

    // Pan (yaw) — analyze.py on real game footage recommended 1.6; was 0.8 (too slow for fast breaks)
    private let Kp: Double = 1.6
    private let maxPanVelocity: Double = 1.5     // rad/s ≈ 86°/s — fast enough for full-court fast breaks
    private let panDeadband: CGFloat = 0.03      // 3% of frame center

    // Tilt (pitch) — gentler than pan to avoid vertical hunting
    private let KpTilt: Double = 0.4             // keep conservative — tilt misbehavior is more jarring
    private let maxTiltVelocity: Double = 0.3    // rad/s — slower than pan for stability
    private let tiltDeadband: CGFloat = 0.08     // 8% — wider deadband to avoid jitter

    // Gravity drift: if no players detected for 5s, slowly tilt down (court is below camera)
    private let gravityTiltVelocity: Double = -0.05  // gentle downward drift rad/s
    private var lastDetectionTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()

    private var lastActionCenterX: CGFloat = 0.5

    // MARK: - IMU (Court Calibration)

    /// Phone yaw from CMMotionManager (radians, world frame).
    /// Used by CourtHeatmapAccumulator to compensate for gimbal pan.
    /// Updated at 30Hz; safe to read from any thread (nonisolated(unsafe)).
    nonisolated(unsafe) private(set) var currentYaw: Double = 0
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    // MARK: - Initialization

    private init() {
        checkDockKitAvailability()
    }

    // MARK: - DockKit Availability

    private func checkDockKitAvailability() {
        #if canImport(DockKit)
        if #available(iOS 18.0, *) {
            debugPrint("[DockKit] iOS 18+ detected, starting accessory scan...")
            Task {
                do {
                    let manager = DockAccessoryManager.shared
                    debugPrint("[DockKit] Got DockAccessoryManager, waiting for accessoryStateChanges...")
                    let stateChanges = try manager.accessoryStateChanges

                    for await stateChange in stateChanges {
                        debugPrint("[DockKit] State change received!")
                        if let accessory = stateChange.accessory {
                            // Immediately disable Insta360's own tracking AI the moment the
                            // gimbal connects. This is the DockKit equivalent of Lock mode —
                            // the gimbal stabilizes but does not track on its own.
                            // Skynet will steer it via updateTrackingROI(center:).
                            try? await manager.setSystemTrackingEnabled(false)
                            debugPrint("[DockKit] ✅ Gimbal connected: \(accessory.identifier.name) — Lock mode engaged")
                            await MainActor.run {
                                self.dockAccessory = accessory
                                self.isDockKitAvailable = true
                            }
                        } else {
                            await MainActor.run {
                                self.dockAccessory = nil
                                self.isDockKitAvailable = false
                                debugPrint("[DockKit] ❌ Gimbal disconnected")
                            }
                        }
                    }
                } catch {
                    debugPrint("[DockKit] ❌ Error: \(error.localizedDescription)")
                    await MainActor.run {
                        self.isDockKitAvailable = false
                        self.lastError = error.localizedDescription
                    }
                }
            }
        } else {
            debugPrint("[DockKit] ❌ iOS version < 18, DockKit not available")
            isDockKitAvailable = false
        }
        #else
        debugPrint("[DockKit] ❌ DockKit framework not available (not imported)")
        isDockKitAvailable = false
        #endif
    }

    // MARK: - Tracking Control

    func startTracking() {
        // If mode is off, don't do anything
        guard gimbalMode != .off else {
            debugPrint("[Gimbal] Mode is OFF, skipping gimbal")
            return
        }

        #if canImport(DockKit)
        guard let _ = dockAccessory else {
            lastError = "No gimbal connected"
            return
        }

        if #available(iOS 18.0, *) {
            isTrackingActive = true
            lastError = nil
            lastActionCenterX = 0.5
            startIMU()

            Task {
                do {
                    let manager = DockAccessoryManager.shared
                    // CRITICAL: Disable DockKit's own tracking AI entirely.
                    // The Insta360 Flow Pro 2 is used as a pure 2-axis physical stabilizer.
                    // Skynet (AutoZoomManager) is the sole tracking brain. It calls
                    // updateTrackingROI(center:) each frame to steer where the gimbal points.
                    try await manager.setSystemTrackingEnabled(false)
                    debugPrint("[Gimbal] System tracking DISABLED — Skynet is in command")
                } catch {
                    await MainActor.run {
                        self.lastError = error.localizedDescription
                        self.isTrackingActive = false
                    }
                }
            }
        }
        #endif
    }

    func stopTracking() {
        guard isTrackingActive else { return }

        trackingTask?.cancel()
        trackingTask = nil
        roiUpdateTask?.cancel()
        roiUpdateTask = nil

        isTrackingActive = false
        trackedSubjectCount = 0
        stopIMU()

        // Send zero velocity so the gimbal doesn't continue panning after tracking stops
        #if canImport(DockKit)
        if #available(iOS 18.0, *), let accessory = dockAccessory {
            Task { try? await accessory.setAngularVelocity(Vector3D(x: 0, y: 0, z: 0)) }
        }
        #endif
    }

    // MARK: - IMU (Court Calibration)

    private func startIMU() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionQueue.maxConcurrentOperationCount = 1
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.currentYaw = motion.attitude.yaw
        }
    }

    private func stopIMU() {
        motionManager.stopDeviceMotionUpdates()
    }

    // MARK: - Skynet-Driven Physical Gimbal Steering (PID velocity control)

    /// Called by AutoZoomManager each frame with Skynet's computed action center (normalized 0–1).
    ///
    /// Uses setAngularVelocity instead of setRegionOfInterest. ROI hints tell DockKit "look here"
    /// and it interprets the request — slow, indirect, imprecise. Angular velocity is a direct
    /// motor command: error → velocity → move. Response is immediate and proportional.
    ///
    /// P controller (pan axis only):
    ///   error = actionCenter.x - 0.5   (positive = subject right of center)
    ///   panVelocity = Kp × error        (clamped to ±maxPanVelocity rad/s)
    ///   velocity = 0 when |error| < deadband  (stops the gimbal precisely at center)
    ///
    /// Axis convention (DockKit / Spatial.Vector3D for a portrait gimbal in landscape):
    ///   Y axis = yaw (left/right pan). X = pitch (tilt). Z = roll (locked, always 0).
    func updateTrackingROI(center: CGPoint) {
        guard gimbalMode == .track, isDockKitAvailable, isTrackingActive else { return }

        lastActionCenterX = center.x
        lastDetectionTime = CFAbsoluteTimeGetCurrent()

        roiUpdateTask?.cancel()
        roiUpdateTask = Task {
            #if canImport(DockKit)
            if #available(iOS 18.0, *) {
                guard let accessory = dockAccessory else { return }

                // Pan error: how far subject is from horizontal center
                let panError = Double(center.x) - 0.5

                // Tilt error: how far subject is from vertical center
                // Vision coords: y=0 bottom, y=1 top. center.y < 0.5 = players in lower frame = tilt down
                let tiltError = Double(center.y) - 0.5

                // Pan velocity (Y axis = yaw)
                let panVelocity: Double
                if abs(panError) > Double(panDeadband) {
                    panVelocity = max(-maxPanVelocity, min(maxPanVelocity, -Kp * panError))
                } else {
                    panVelocity = 0
                }

                // Tilt velocity (X axis = pitch)
                // Positive X = tilt up (towards y=1), negative X = tilt down (towards y=0)
                // May need sign flip — verify at first game, same as we did for pan
                let tiltVelocity: Double
                if abs(tiltError) > Double(tiltDeadband) {
                    tiltVelocity = max(-maxTiltVelocity, min(maxTiltVelocity, KpTilt * tiltError))
                } else {
                    tiltVelocity = 0
                }

                guard panVelocity != 0 || tiltVelocity != 0 else {
                    try? await accessory.setAngularVelocity(Vector3D(x: 0, y: 0, z: 0))
                    return
                }

                let velocity = Vector3D(x: tiltVelocity, y: panVelocity, z: 0)
                do {
                    try await accessory.setAngularVelocity(velocity)
                    #if DEBUG
                    debugPrint("[Gimbal] PID pan → err:\(String(format: "%.3f", panError)) vel:\(String(format: "%.2f", panVelocity)) rad/s")
                    #endif
                } catch {
                    // setAngularVelocity unsupported or failed — fall back to ROI hint (old method).
                    // This ensures the game is never broken by an untested API.
                    debugPrint("[Gimbal] setAngularVelocity failed, falling back to ROI: \(error.localizedDescription)")
                    let halfWidth: CGFloat = 0.25 / 2
                    let roi = CGRect(
                        x: max(0, min(0.75, CGFloat(center.x) - halfWidth)),
                        y: 0.05, width: 0.25, height: 0.90
                    )
                    try? await accessory.setRegionOfInterest(roi)
                }
            }
            #endif
        }
    }

    /// Call when no players are detected — after 5s of no detections, slowly tilt down
    /// (gravity heuristic: the court is always below the camera, never above)
    func applyGravityDrift() {
        guard gimbalMode == .track, isDockKitAvailable, isTrackingActive else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - lastDetectionTime
        guard elapsed > 5.0 else { return }

        roiUpdateTask?.cancel()
        roiUpdateTask = Task {
            #if canImport(DockKit)
            if #available(iOS 18.0, *) {
                guard let accessory = dockAccessory else { return }
                try? await accessory.setAngularVelocity(Vector3D(x: gravityTiltVelocity, y: 0, z: 0))
            }
            #endif
        }
    }

    // MARK: - Status

    func getStatusText() -> String {
        if !isDockKitAvailable {
            return "No gimbal"
        }
        if isTrackingActive {
            return trackedSubjectCount > 0 ? "Tracking \(trackedSubjectCount)" : "Tracking"
        }
        return "Ready"
    }
}
