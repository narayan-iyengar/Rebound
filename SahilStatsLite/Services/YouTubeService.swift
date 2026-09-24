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
import AuthenticationServices
import CryptoKit
import UIKit

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

    // Which YouTube channel the current token uploads to — so the user can SEE and
    // confirm it's "SahilHoops" and not their personal channel. A Google account with
    // multiple channels picks the target at sign-in; the API can't choose it afterward.
    @Published var connectedChannelTitle: String?
    @Published var connectedChannelId: String?

    // Holds the PKCE verifier across the ASWebAuthenticationSession round-trip.
    private var pkceVerifier: String?
    private var webAuthSession: ASWebAuthenticationSession?

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

    // Sequential upload queue: tapping Upload on several games lines them up and they
    // upload one after another (safer than parallel 4K uploads over cellular). The
    // active upload uses isUploading/currentUploadingGameID/uploadProgress above; these
    // hold the ones still waiting so the UI can show "Queued".
    struct QueuedUpload: Sendable { let gameID: String; let url: URL; let title: String; let description: String }
    private var uploadQueue: [QueuedUpload] = []
    @Published var queuedGameIDs: Set<String> = []

    private override init() {
        super.init()
        checkAuthorization()
        cancelOrphanedUploads()
    }

    /// Cancel background upload tasks left over from a previous app session (app killed or
    /// reinstalled mid-upload). Their delegate callbacks otherwise keep updating the shared
    /// progress — the jumpy 2%→60% — and could even finish an upload to the wrong channel.
    /// Safe to call once at launch, when no in-app upload is in flight.
    func cancelOrphanedUploads() {
        backgroundSession.getAllTasks { [weak self] tasks in
            guard let self else { return }
            guard !tasks.isEmpty else { return }
            for t in tasks { t.cancel() }
            debugPrint("📺 Cancelled \(tasks.count) orphaned background upload task(s) at launch")
            Task { @MainActor in
                self.isUploading = false
                self.currentUploadingGameID = nil
                self.uploadProgress = 0
                self.currentTaskID = nil
            }
        }
    }

    // MARK: - Authorization

    func checkAuthorization() {
        isAuthorized = getKeychainValue(key: accessTokenKey) != nil
        if isAuthorized { Task { await fetchConnectedChannel() } }
    }

    // MARK: - Channel-chooser sign-in (independent of the app's Google login)
    //
    // The app's Firebase login and YouTube share GIDSignIn.sharedInstance, so signing
    // out to re-pick a channel would also log the user out of the app. This flow uses a
    // SEPARATE OAuth web session (ASWebAuthenticationSession + PKCE) so it (a) never
    // touches the app login, and (b) forces Google's account + CHANNEL chooser every
    // time (prompt=consent select_account), which is the only way to target a Brand
    // Account channel like "SahilHoops" instead of the personal default.

    private let oauthScopes = ["https://www.googleapis.com/auth/youtube",
                               "https://www.googleapis.com/auth/youtube.upload"]

    func authorizeWithChannelChooser() async throws {
        guard let clientId = getClientId(),
              let reversed = getReversedClientId() else {
            throw YouTubeError.invalidConfiguration
        }
        let redirectURI = "\(reversed):/oauth2redirect"
        let callbackScheme = reversed

        let verifier = Self.makeCodeVerifier()
        pkceVerifier = verifier
        let challenge = Self.codeChallenge(for: verifier)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: oauthScopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            // Force the account + channel picker and guarantee a refresh token.
            .init(name: "prompt", value: "consent select_account")
        ]
        guard let authURL = comps.url else { throw YouTubeError.invalidConfiguration }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { url, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let url = url else { continuation.resume(throwing: YouTubeError.uploadFailed("Sign-in returned no result")); return }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false // reuse Google login, just re-pick channel
            self.webAuthSession = session
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw YouTubeError.uploadFailed("No authorization code returned")
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier,
                                        clientId: clientId, redirectURI: redirectURI)
        isAuthorized = true
        await fetchConnectedChannel()
    }

    private func exchangeCodeForTokens(code: String, verifier: String,
                                       clientId: String, redirectURI: String) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "code", value: code),
            .init(name: "code_verifier", value: verifier),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: redirectURI)
        ]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw YouTubeError.uploadFailed("Token exchange failed (\(status)): \(bodyStr.prefix(200))")
        }
        // A refresh token only comes back with prompt=consent; keep the old one if absent.
        let refresh = (json["refresh_token"] as? String) ?? getKeychainValue(key: refreshTokenKey) ?? ""
        try saveTokens(accessToken: access, refreshToken: refresh)
    }

    /// Ask YouTube which channel this token belongs to, so the UI can show it and the
    /// user can confirm it's SahilHoops before uploading.
    func fetchConnectedChannel() async {
        guard let token = try? await getFreshAccessToken(),
              let url = URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]], let first = items.first else { return }
        connectedChannelId = first["id"] as? String
        connectedChannelTitle = (first["snippet"] as? [String: Any])?["title"] as? String
    }

    private func getReversedClientId() -> String? {
        guard let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
              let plist = NSDictionary(contentsOfFile: path) else { return nil }
        return plist["REVERSED_CLIENT_ID"] as? String
    }

    // MARK: PKCE
    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
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
        connectedChannelTitle = nil
        connectedChannelId = nil
    }

    // MARK: - Upload

    /// Enqueue a game for upload. If nothing is uploading it starts immediately; otherwise
    /// it waits its turn and runs when the current one finishes. Tapping Upload on several
    /// games just queues them.
    func uploadVideo(url: URL, title: String, description: String, gameID: String) async {
        guard isAuthorized else {
            debugPrint("📺 YouTube upload skipped (not authorized)")
            return
        }
        // De-dupe: ignore if it's already the active upload or already queued.
        if currentUploadingGameID == gameID || uploadQueue.contains(where: { $0.gameID == gameID }) {
            debugPrint("📺 \(gameID) already uploading/queued — ignoring duplicate tap")
            return
        }
        uploadQueue.append(QueuedUpload(gameID: gameID, url: url, title: title, description: description))
        queuedGameIDs.insert(gameID)
        debugPrint("📺 Queued upload for \(gameID) (\(uploadQueue.count) waiting)")
        await drainQueue()
    }

    /// Start the next queued upload if the pipe is free.
    private func drainQueue() async {
        guard !isUploading, let item = uploadQueue.first else { return }
        uploadQueue.removeFirst()
        queuedGameIDs.remove(item.gameID)

        isUploading = true
        currentUploadingGameID = item.gameID
        completedVideoID = nil
        uploadProgress = 0
        lastError = nil
        await performUpload(item)
    }

    private func performUpload(_ item: QueuedUpload) async {
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            failCurrent(item, "Video file not found")
            return
        }

        // Verify file is a playable video before uploading. Catches corrupt MOV files
        // (truncated MOOV atom from app force-quit mid-write) that would upload
        // "successfully" but get "Processing abandoned" by YouTube.
        let asset = AVURLAsset(url: item.url)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let duration = (try? await asset.load(.duration)) ?? .zero
        let durationSec = CMTimeGetSeconds(duration)
        guard isPlayable, durationSec.isFinite, durationSec > 1 else {
            debugPrint("📺 Refusing to upload corrupt/empty video (playable=\(isPlayable), duration=\(durationSec)s)")
            failCurrent(item, "Video file is corrupt or empty — recording may have ended unexpectedly. Re-record or recover from Photos.")
            return
        }
        debugPrint("📺 Pre-upload check OK: duration=\(Int(durationSec))s, playable=\(isPlayable)")

        do {
            let accessToken = try await getFreshAccessToken()
            let fileSize = try FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as! Int
            let uploadURL = try await initializeUpload(title: item.title, description: item.description, accessToken: accessToken, fileSize: fileSize)
            startBackgroundUpload(fileURL: item.url, uploadURL: uploadURL)
            // Completion (success/fail) + advancing to the next item happens in the
            // URLSession delegate (didCompleteWithError).
        } catch {
            debugPrint("📺 Upload failed to start: \(error.localizedDescription)")
            failCurrent(item, error.localizedDescription)
        }
    }

    /// Mark the current item failed, notify, and move on to the next queued upload so one
    /// bad file doesn't stall the whole batch.
    private func failCurrent(_ item: QueuedUpload, _ message: String) {
        lastError = message
        isUploading = false
        currentUploadingGameID = nil
        currentTaskID = nil
        uploadProgress = 0
        onUploadCompleted?(item.gameID, false, nil)
        Task { await drainQueue() }
    }

    func cancelUpload() {
        // Cancel the active upload…
        if let taskID = currentTaskID {
            backgroundSession.getAllTasks { tasks in
                if let task = tasks.first(where: { $0.taskIdentifier == taskID }) {
                    task.cancel()
                    debugPrint("📺 Upload cancelled by user")
                }
            }
        }
        // …and drop everything still queued (a batch cancel).
        let cancelledQueued = uploadQueue.map(\.gameID)
        uploadQueue.removeAll()
        queuedGameIDs.removeAll()
        for id in cancelledQueued { onUploadCompleted?(id, false, nil) }

        isUploading = false
        currentUploadingGameID = nil
        currentTaskID = nil
        uploadProgress = 0
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
    /// Recover a previously-uploaded video's id by searching the user's own uploads by title.
    /// For games uploaded before we started persisting youtubeVideoId → restores their
    /// "Watch on YouTube" link without a re-upload.
    func findUploadedVideoId(title: String) async -> String? {
        guard let token = try? await getFreshAccessToken() else { return nil }
        let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        guard let url = URL(string: "https://www.googleapis.com/youtube/v3/search?part=snippet&forMine=true&type=video&maxResults=10&q=\(q)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return nil }
        func videoId(_ item: [String: Any]) -> String? { (item["id"] as? [String: Any])?["videoId"] as? String }
        // Prefer an exact title match, else the top result.
        for item in items {
            if let snip = item["snippet"] as? [String: Any], (snip["title"] as? String) == title,
               let vid = videoId(item) { return vid }
        }
        return items.first.flatMap(videoId)
    }

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
        let taskID = task.taskIdentifier
        Task { @MainActor in
            // Ignore progress from stale/orphaned tasks (e.g. a leftover upload after a
            // reinstall) — otherwise two tasks fight over one bar and it jumps around.
            guard taskID == self.currentTaskID else { return }
            self.uploadProgress = progress
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let transportError = error
        let taskID = task.taskIdentifier
        Task { @MainActor in
            // A leftover/orphaned task (e.g. cancelled at launch after a reinstall) must not
            // overwrite the current upload's state or a game's status.
            if let current = self.currentTaskID, taskID != current { return }

            let gameID = self.currentUploadingGameID
            let videoID = self.completedVideoID

            self.isUploading = false
            self.currentUploadingGameID = nil
            self.completedVideoID = nil
            self.currentTaskID = nil

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

            // Advance to the next queued upload, if any.
            await self.drainQueue()
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

// MARK: - Web auth presentation

extension YouTubeService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Must return synchronously on the main thread; grab the current key window.
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            return scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first ?? ASPresentationAnchor()
        }
    }
}

// MARK: - Base64URL

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
