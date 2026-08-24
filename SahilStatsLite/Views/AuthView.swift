//
//  AuthView.swift
//  SahilStatsLite
//
//  PURPOSE: Sign-in view for Firebase authentication. Shows Google Sign-In
//           button, current auth status, and sync controls for game data.
//  KEY TYPES: AuthView
//  DEPENDS ON: AuthService, GamePersistenceManager
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI

struct AuthView: View {
    @ObservedObject private var authService = AuthService.shared
    @ObservedObject private var persistenceManager = GamePersistenceManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Chalk header replaces the system nav bar.
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Chalk.chalk)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                VStack(spacing: 32) {
                    Spacer()

                    // Wordmark and tagline
                    VStack(spacing: 16) {
                        ReboundWordmark(size: 52)

                        Text("Sign in to sync your games across devices")
                            .font(.system(size: 15))
                            .foregroundColor(Chalk.dust)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Spacer()

                    // Sign-in options
                    VStack(spacing: 16) {
                        if authService.isSignedIn {
                            // Already signed in
                            signedInView
                        } else {
                            // Sign in with Google
                            ChalkButton(title: "Sign in with Google", icon: "g.circle.fill", color: Chalk.yellow) {
                                Task {
                                    await authService.signInWithGoogle()
                                }
                            }
                            .padding(.horizontal, 32)
                            .disabled(authService.isLoading)

                            // Continue without signing in
                            Button {
                                dismiss()
                            } label: {
                                Text("Continue without signing in")
                                    .font(.system(size: 15))
                                    .foregroundColor(Chalk.dust)
                            }
                            .padding(.top, 8)
                        }
                    }

                    // Error display
                    if let error = authService.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(Chalk.coral)
                            .padding(.horizontal)
                    }

                    // Loading indicator
                    if authService.isLoading {
                        ProgressView()
                            .tint(Chalk.chalk)
                            .padding()
                    }

                    Spacer()

                    // Privacy note
                    Text("Your data is stored securely in Firebase")
                        .font(.caption2)
                        .foregroundColor(Chalk.dust.opacity(0.7))
                        .padding(.bottom)
                }
            }
            .chalkBoard()
            .navigationBarHidden(true)
        }
    }

    // MARK: - Signed In View

    private var signedInView: some View {
        VStack(spacing: 20) {
            // User info
            VStack(spacing: 8) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(Chalk.green)

                Text("Signed In")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Chalk.green)

                if let email = authService.userEmail {
                    Text(email)
                        .font(.system(size: 15))
                        .foregroundColor(Chalk.dust)
                }
            }

            // Sync status
            HStack(spacing: 8) {
                if persistenceManager.isSyncing {
                    ProgressView()
                        .scaleEffect(0.8)
                        .tint(Chalk.chalk)
                    Text("Syncing...")
                } else if let lastSync = persistenceManager.lastSyncTime {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundColor(Chalk.green)
                    Text("Last synced: \(lastSync.formatted(date: .omitted, time: .shortened))")
                } else {
                    Image(systemName: "icloud.fill")
                        .foregroundColor(Chalk.sky)
                    Text("Connected to cloud")
                }
            }
            .font(.system(size: 12))
            .foregroundColor(Chalk.dust)

            // Sync error
            if let syncError = persistenceManager.syncError {
                Text(syncError)
                    .font(.system(size: 12))
                    .foregroundColor(Chalk.coral)
            }

            // Actions
            VStack(spacing: 12) {
                // Force sync button
                ChalkButton(title: "Sync Now", icon: "arrow.triangle.2.circlepath",
                            color: Chalk.chalk, filled: false) {
                    Task {
                        await persistenceManager.forceSyncFromFirebase()
                    }
                }
                .disabled(persistenceManager.isSyncing)

                // Sign out button
                ChalkButton(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right",
                            color: Chalk.coral, filled: false) {
                    authService.signOut()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 16)
        }
    }
}

#Preview {
    AuthView()
}
