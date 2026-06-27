//
//  YouTubeService.swift
//  SahilStatsLite
//
//  PURPOSE: Lean YouTube upload service. Google Sign-In for OAuth, Keychain for
//           token storage, immediate upload over 5G (no WiFi queue). Auto-uploads
//           game videos as public to Sahil's YouTube channel.
//  KEY TYPES: YouTubeService (singleton, @MainActor)
//  DEPENDS ON: GoogleSignIn, Security (Keychain)
//
//  NOTE: Keep this header updated when modifying this file.
//

import Foundation
import Security
import AVFoundation
import GoogleSignIn
import Combine

@MainActor
class YouTubeService: NSObject, ObservableObject {
    static let shared = YouTubeService()

    // State
    @Published var isAuthorized: Bool = false
    @Published var isUploading: Bool = false
    @Published var uploadProgress: Double = 0
    @Published var lastError: String?
    @Published var currentUploadingGameID: String?
    @Published var completedVideoID: String?
    
    // Callback for completion (GameID, Success, VideoID?)
    var onUploadCompleted: ((String, Bool, String?) -> Void)?

    private let keychainService = "com.narayan.SahilStats.youtube"
    private let accessTokenKey = "accessToken"
    private let refreshTokenKey = "refreshToken"
    private let tokenTimestampKey = "tokenTimestamp"
    
    // Background Session
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.narayan.SahilStats.youtube.upload")
        config.isDiscretionary = false // Start immediately
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    // Track current upload task ID to match delegate callbacks
    private var currentTaskID: Int?

    private override init() {
        super.init()
        checkAuthorization()
    }

    // MARK: - Authorization

    func checkAuthorization() {
        isAuthorized = getKeychainValue(key: accessTokenKey) != nil
    }

    func authorize() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw YouTubeError.noViewController
        }

        // youtube scope needed for live broadcast management (create/start/end broadcasts)
        let scopes = ["https://www.googleapis.com/auth/youtube",
                      "https://www.googleapis.com/auth/youtube.upload"]

        // Use existing Google Sign-In user if available
        if let currentUser = GIDSignIn.sharedInstance.currentUser {
            let grantedScopes = currentUser.grantedScopes ?? []
            if scopes.allSatisfy({ grantedScopes.contains($0) }) {
                // Already have YouTube scope
                try saveTokens(
                    accessToken: currentUser.accessToken.tokenString,
                    refreshToken: currentUser.refreshToken.tokenString
                )
                isAuthorized = true
                return
            }
        }

        // Request sign-in with YouTube scope
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: rootViewController,
            hint: GIDSignIn.sharedInstance.currentUser?.profile?.email,
            additionalScopes: scopes
        )

        try saveTokens(
            accessToken: result.user.accessToken.tokenString,
            refreshToken: result.user.refreshToken.tokenString
        )
        isAuthorized = true
    }

    func revokeAccess() {
        deleteKeychainValue(key: accessTokenKey)
        deleteKeychainValue(key: refreshTokenKey)
        deleteKeychainValue(key: tokenTimestampKey)
        isAuthorized = false
    }

    // MARK: - Upload

    func uploadVideo(url: URL, title: String, description: String, gameID: String) async {
        guard isAuthorized else {
            debugPrint("📺 YouTube upload skipped (not authorized)")
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            debugPrint("📺 Video file not found: \(url.path)")
            lastError = "Video file not found"
            return
        }

        // Verify file is a playable video before uploading. Catches corrupt MOV
        // files (truncated MOOV atom from app force-quit mid-write) that would
        // upload "successfully" but get "Processing abandoned" by YouTube.
        let asset = AVURLAsset(url: url)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSec = CMTimeGetSeconds(duration)
        guard isPlayable, durationSec.isFinite, durationSec > 1 else {
            debugPrint("📺 Refusing to upload corrupt/empty video (playable=\(isPlayable), duration=\(durationSec)s)")
            lastError = "Video file is corrupt or empty — recording may have ended unexpectedly. Re-record or recover from Photos."
            return
        }
        debugPrint("📺 Pre-upload check OK: duration=\(Int(durationSec))s, playable=\(isPlayable)")

        isUploading = true
        currentUploadingGameID = gameID
        completedVideoID = nil
        uploadProgress = 0
        lastError = nil

        do {
            let accessToken = try await getFreshAccessToken()

            // Step 1: Initialize Resumable Upload (Foreground - fast)
            let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
            let uploadURL = try await initializeUpload(title: title, description: description, accessToken: accessToken, fileSize: fileSize)

            // Step 2: Start Background Upload
            startBackgroundUpload(fileURL: url, uploadURL: uploadURL)

        } catch {
            debugPrint("📺 Upload failed to start: \(error.localizedDescription)")
            lastError = error.localizedDescription
            isUploading = false
            currentUploadingGameID = nil
        }
    }

    func cancelUpload() {
        guard let taskID = currentTaskID else { return }
        backgroundSession.getAllTasks { tasks in
            if let task = tasks.first(where: { $0.taskIdentifier == taskID }) {
                task.cancel()
                debugPrint("📺 Upload cancelled by user")
            }
        }
        Task { @MainActor in
            isUploading = false
            currentUploadingGameID = nil
            uploadProgress = 0
        }
    }

    // MARK: - Live Broadcast Management

    /// Creates an unlisted Sports broadcast, returns (broadcastId, watchURL).
    /// Call before streaming starts to get the watch URL and prepare YouTube.
    func createBroadcast(title: String) async throws -> (id: String, watchURL: String) {
        let token = try await getFreshAccessToken()
        let now = ISO8601DateFormatter().string(from: Date())

        let body: [String: Any] = [
            "snippet": [
                "title": title,
                "scheduledStartTime": now,
                "description": "Live basketball game streamed with Rebound."
            ],
            "status": [
                "privacyStatus": "unlisted",
                "selfDeclaredMadeForKids": false
            ],
            "contentDetails": [
                "monitorStream": ["enableMonitorStream": false],
                "enableAutoStart": true,
                "enableAutoStop": true,
                "latencyPreference": "ultraLow"
            ]
        ]

        let urlStr = "https://www.googleapis.com/youtube/v3/liveBroadcasts?part=id,snippet,status,contentDetails"
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseBody = String(data: data, encoding: .utf8) ?? "no body"
        debugPrint("[YouTube] createBroadcast response \(httpStatus): \(responseBody)")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String else {
            throw YouTubeError.uploadFailed("Broadcast failed (\(httpStatus)): \(responseBody.prefix(200))")
        }

        // Set category to Sports (17) via video update
        try? await setCategoryAndBindStream(broadcastId: id, title: title, token: token)

        let watchURL = "https://youtube.com/live/\(id)"
        debugPrint("📡 Broadcast created: \(id) → \(watchURL)")
        return (id, watchURL)
    }

    private func setCategoryAndBindStream(broadcastId: String, title: String, token: String) async throws {
        // Update the broadcast video's category to Sports (17)
        let body: [String: Any] = ["id": broadcastId,
                                    "snippet": ["categoryId": "17",
                                                "title": title]]
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/videos?part=snippet")!)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Bind the broadcast to the default stream key and transition to live.
    func startBroadcast(broadcastId: String, streamKey: String) async throws {
        let token = try await getFreshAccessToken()

        // Find the liveStream ID for this channel
        var listReq = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/liveStreams?part=id,cdn&mine=true&maxResults=10")!)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: listReq)
        let listStatus = (listResp as? HTTPURLResponse)?.statusCode ?? 0
        let listBody = String(data: listData, encoding: .utf8) ?? ""
        debugPrint("[YouTube] liveStreams list \(listStatus): \(listBody.prefix(500))")

        guard let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let items = listJson["items"] as? [[String: Any]],
              let streamId = items.first.flatMap({ ($0["id"] as? String) }) else {
            debugPrint("[YouTube] No liveStream found, cannot bind")
            return
        }

        // Bind stream to broadcast
        var bindReq = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts/bind?id=\(broadcastId)&streamId=\(streamId)&part=id")!)
        bindReq.httpMethod = "POST"
        bindReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bindData, bindResp) = try await URLSession.shared.data(for: bindReq)
        let bindStatus = (bindResp as? HTTPURLResponse)?.statusCode ?? 0
        let bindBody = String(data: bindData, encoding: .utf8) ?? ""
        debugPrint("[YouTube] bind \(bindStatus): \(bindBody.prefix(300))")
        debugPrint("[YouTube] Broadcast \(broadcastId) bound to stream \(streamId)")
    }

    /// End the broadcast cleanly.
    func endBroadcast(broadcastId: String) async {
        guard let token = try? await getFreshAccessToken() else { return }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/liveBroadcasts/transition?broadcastStatus=complete&id=\(broadcastId)&part=id")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        debugPrint("[YouTube] endBroadcast \(broadcastId): \(status) \(body.prefix(200))")
    }

    /// Delete a video from YouTube (used to remove inferior stream recording after 4K upload).
    func deleteVideo(videoId: String) async {
        guard let token = try? await getFreshAccessToken() else { return }
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/videos?id=\(videoId)")!)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = (try? await URLSession.shared.data(for: req)) ?? (Data(), nil)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 204 = success, 404 = already deleted
        debugPrint("[YouTube] deleteVideo \(videoId): \(status)")
    }

    private func initializeUpload(title: String, description: String, accessToken: String, fileSize: Int) async throws -> URL {
        let metadata: [String: Any] = [
            "snippet": [
                "title": title,
                "description": description,
                "categoryId": "17" // Sports
            ],
            "status": [
                "privacyStatus": "unlisted",
                // CRITICAL: without this YouTube auto-flags as kids content (channel
                // context + youth basketball titles) which kills comments/notifications/analytics.
                "selfDeclaredMadeForKids": false
            ]
        ]

        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        // Upload to Sahil Hoops channel so recordings + live streams are in one place
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue("video/*", forHTTPHeaderField: "X-Upload-Content-Type")
        request.httpBody = metadataJSON

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw YouTubeError.uploadFailed("Invalid response type")
        }
        
        if let location = httpResponse.value(forHTTPHeaderField: "Location"),
           let uploadURL = URL(string: location) {
            return uploadURL
        } else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            debugPrint("❌ YouTube Init Failed: \(httpResponse.statusCode)")
            debugPrint("❌ Body: \(body)")
            
            if body.contains("uploadLimitExceeded") {
                throw YouTubeError.uploadFailed("Daily YouTube upload limit reached. Please wait 24 hours.")
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw YouTubeError.uploadFailed("YouTube permission denied. Please reconnect account.")
            } else {
                throw YouTubeError.uploadFailed("Upload failed (Server \(httpResponse.statusCode))")
            }
        }
    }
    
    private func startBackgroundUpload(fileURL: URL, uploadURL: URL) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("video/*", forHTTPHeaderField: "Content-Type")
        
        let task = backgroundSession.uploadTask(with: request, fromFile: fileURL)
        currentTaskID = task.taskIdentifier
        task.resume()
        debugPrint("📺 Background upload task started (ID: \(task.taskIdentifier))")
    }

    private func performUpload(url videoURL: URL, title: String, description: String) async throws -> String {
        // Legacy method - replaced by background flow
        return ""
    }

    // MARK: - Token Management

    private func getFreshAccessToken() async throws -> String {
        guard let accessToken = getKeychainValue(key: accessTokenKey) else {
            throw YouTubeError.notAuthorized
        }

        // Check if token is old (>45 minutes)
        if let timestampStr = getKeychainValue(key: tokenTimestampKey),
           let timestamp = Double(timestampStr) {
            let tokenAge = Date().timeIntervalSince1970 - timestamp
            if tokenAge > 45 * 60 {
                // Refresh token
                return try await refreshAccessToken()
            }
        }

        return accessToken
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = getKeychainValue(key: refreshTokenKey) else {
            throw YouTubeError.notAuthorized
        }

        guard let clientId = getClientId() else {
            throw YouTubeError.invalidConfiguration
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "client_id=\(clientId)&refresh_token=\(refreshToken)&grant_type=refresh_token"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw YouTubeError.tokenRefreshFailed
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let newAccessToken = json?["access_token"] as? String else {
            throw YouTubeError.tokenRefreshFailed
        }

        // Save new token
        setKeychainValue(key: accessTokenKey, value: newAccessToken)
        setKeychainValue(key: tokenTimestampKey, value: String(Date().timeIntervalSince1970))

        return newAccessToken
    }

    private func saveTokens(accessToken: String, refreshToken: String) throws {
        setKeychainValue(key: accessTokenKey, value: accessToken)
        setKeychainValue(key: refreshTokenKey, value: refreshToken)
        setKeychainValue(key: tokenTimestampKey, value: String(Date().timeIntervalSince1970))
    }

    private func getClientId() -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path),
              let clientId = plist["CLIENT_ID"] as? String else {
            return nil
        }
        return clientId
    }

    // MARK: - Keychain Helpers

    private func setKeychainValue(key: String, value: String) {
        let data = value.data(using: .utf8)!

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)

        var newQuery = query
        newQuery[kSecValueData as String] = data

        SecItemAdd(newQuery as CFDictionary, nil)
    }

    private func getKeychainValue(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    private func deleteKeychainValue(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - URLSessionTaskDelegate

extension YouTubeService: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in
            self.uploadProgress = progress
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let transportError = error
        Task { @MainActor in
            let gameID = self.currentUploadingGameID
            let videoID = self.completedVideoID

            self.isUploading = false
            self.currentUploadingGameID = nil
            self.completedVideoID = nil

            // Real success requires: no transport error + 2xx HTTP status + we got a video ID back.
            // Previously we only checked transport error, so HTTP 4xx (YouTube rejected) and
            // missing-ID responses were silently treated as success.
            let httpOK = (200..<300).contains(httpStatus)
            let success = transportError == nil && httpOK && videoID != nil

            if success {
                debugPrint("📺 Background upload completed successfully (id=\(videoID ?? "?"))")
                self.uploadProgress = 1.0
                if let id = gameID {
                    self.onUploadCompleted?(id, true, videoID)
                }
            } else {
                let reason: String
                if let err = transportError {
                    reason = err.localizedDescription
                } else if !httpOK {
                    reason = "YouTube rejected upload (HTTP \(httpStatus))"
                } else {
                    reason = "Upload finished but no video ID returned"
                }
                debugPrint("📺 Background upload failed: \(reason)")
                self.lastError = reason
                if let id = gameID {
                    self.onUploadCompleted?(id, false, nil)
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Parse response to get Video ID
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let videoId = json["id"] as? String {
            debugPrint("📺 YouTube Video ID: \(videoId)")
            Task { @MainActor in
                self.completedVideoID = videoId
            }
        }
    }
    
    // Required for background sessions
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            // Call completion handler if stored from AppDelegate
        }
    }
}

// MARK: - Errors

enum YouTubeError: LocalizedError {
    case noViewController
    case notAuthorized
    case invalidConfiguration
    case tokenRefreshFailed
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noViewController:
            return "Unable to present authorization screen"
        case .notAuthorized:
            return "Not authorized for YouTube upload"
        case .invalidConfiguration:
            return "YouTube API not configured"
        case .tokenRefreshFailed:
            return "Failed to refresh YouTube token"
        case .uploadFailed(let message):
            return message
        }
    }
}
