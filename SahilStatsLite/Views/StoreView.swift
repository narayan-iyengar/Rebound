//
//  StoreView.swift
//  SahilStatsLite
//
//  PURPOSE: The "Store" — saved Clips (highlights), grouped by game session
//           (Sahil's team vs opponent · date/time). Tap to play. Long-press to
//           enter multi-select, then tap clips (or a game header to grab the whole
//           game) and delete in bulk — from the app and optionally Photos. No
//           win/loss — clips are self-describing from clip-time metadata.
//  KEY TYPES: StoreView, ClipCard, ClipThumbnail, ClipPlayerSheet
//  DEPENDS ON: HighlightStore, AVKit
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import AVKit
import AVFoundation

struct StoreView: View {
    @ObservedObject private var store = HighlightStore.shared
    @State private var playing: Highlight?

    // Multi-select
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var showDeleteConfirm = false

    // Tag editing
    @State private var editingGroupId: String?
    @State private var labelDraft = ""
    @State private var showTagEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header

                if store.highlights.isEmpty {
                    emptyState
                } else {
                    ForEach(store.grouped) { group in
                        gameSection(group)
                    }
                }

                Spacer(minLength: 30)
            }
            .padding()
        }
        .scrollIndicators(.hidden)
        .chalkBoard()
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .fullScreenCover(item: $playing) { clip in
            VideoPlayerSheet(url: clip.url, caption: clip.isPractice ? "Practice" : clip.scoreLine)
        }
        .alert("Tag", isPresented: $showTagEditor) {
            TextField("e.g. Rec Center · shooting", text: $labelDraft)
            Button("Save") {
                if let gid = editingGroupId { store.setLabel(labelDraft, forGroupId: gid) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Label this session's clips.")
        }
        .confirmationDialog("Delete \(selected.count) clip\(selected.count == 1 ? "" : "s")?",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete from app + Photos", role: .destructive) {
                store.deleteMany(selected, fromPhotos: true)
                exitSelection()
            }
            Button("Delete from app only", role: .destructive) {
                store.deleteMany(selected, fromPhotos: false)
                exitSelection()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleting from Photos will ask for permission. Clips saved before this update can only be removed from the app.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Store")
                    .font(.chalkScript(40))
                    .foregroundColor(Chalk.chalk)
                Text(store.highlights.isEmpty
                     ? "Your saved clips live here"
                     : "\(store.highlights.count) clip\(store.highlights.count == 1 ? "" : "s") · \(store.grouped.count) game\(store.grouped.count == 1 ? "" : "s")")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Chalk.dust)
            }
            Spacer()
            if !store.highlights.isEmpty {
                Button(selecting ? "Cancel" : "Select") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if selecting { exitSelection() } else { selecting = true }
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Chalk.yellow)
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundColor(Chalk.coral.opacity(0.8))
            Text("No clips yet")
                .font(.chalkScript(28))
                .foregroundColor(Chalk.chalk)
            Text("Tap Clip during a game or practice to save the last ~30s as a highlight. Saved clips appear here, grouped by game.")
                .font(.system(size: 15))
                .foregroundColor(Chalk.dust)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .chalkCard()
    }

    // MARK: - Game section

    private func gameSection(_ group: HighlightGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if selecting { toggleGroup(group) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if selecting {
                        Image(systemName: groupAllSelected(group) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(groupAllSelected(group) ? Chalk.yellow : Chalk.dust)
                    }
                    Text(group.matchup)
                        .font(.chalkScript(26))
                        .foregroundColor(Chalk.chalk)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.sessionDate(group.date))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                }
            }
            .buttonStyle(.plain)
            .disabled(!selecting)

            if !selecting { tagChip(group) }

            ForEach(group.clips) { clip in
                ClipCard(clip: clip, selecting: selecting, isSelected: selected.contains(clip.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selecting { toggle(clip) } else { playing = clip }
                    }
                    .onLongPressGesture {
                        if !selecting {
                            withAnimation(.easeInOut(duration: 0.2)) { selecting = true }
                            selected = [clip.id]
                        }
                    }
                    .contextMenu {
                        if !selecting {
                            ShareLink(item: clip.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button { selecting = true; selected = [clip.id] } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            Button(role: .destructive) {
                                selected = [clip.id]
                                // Defer so the context menu dismisses before the dialog shows.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    showDeleteConfirm = true
                                }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
            }
        }
    }

    // Editable tag chip for a session (any group — practice or game).
    private func tagChip(_ group: HighlightGroup) -> some View {
        Button {
            editingGroupId = group.id
            labelDraft = group.label ?? ""
            showTagEditor = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: (group.label?.isEmpty == false) ? "tag.fill" : "tag")
                    .font(.system(size: 11, weight: .semibold))
                Text((group.label?.isEmpty == false) ? group.label! : "Add tag")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor((group.label?.isEmpty == false) ? Chalk.yellow : Chalk.dust)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Selection bar

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button(selected.count == store.highlights.count ? "Deselect All" : "Select All") {
                if selected.count == store.highlights.count { selected.removeAll() }
                else { selected = Set(store.highlights.map(\.id)) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Chalk.chalk)

            Spacer()

            Text("\(selected.count) selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Chalk.dust)

            Spacer()

            Button {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(selected.isEmpty ? Chalk.dust : Chalk.board)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(selected.isEmpty ? Color.clear : Chalk.coral, in: Capsule())
            }
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Chalk.board2.opacity(0.98), in: Capsule())
        .overlay(Capsule().stroke(Chalk.chalk.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Selection helpers

    private func toggle(_ clip: Highlight) {
        if selected.contains(clip.id) { selected.remove(clip.id) } else { selected.insert(clip.id) }
    }
    private func groupAllSelected(_ g: HighlightGroup) -> Bool {
        !g.clips.isEmpty && g.clips.allSatisfy { selected.contains($0.id) }
    }
    private func toggleGroup(_ g: HighlightGroup) {
        if groupAllSelected(g) { g.clips.forEach { selected.remove($0.id) } }
        else { g.clips.forEach { selected.insert($0.id) } }
    }
    private func exitSelection() {
        selecting = false
        selected.removeAll()
    }

    static func sessionDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'Today' · h:mm a"
            : (Calendar.current.isDateInYesterday(date) ? "'Yesterday' · h:mm a" : "MMM d · h:mm a")
        return f.string(from: date)
    }
}

// MARK: - Clip card (one saved highlight)

private struct ClipCard: View {
    let clip: Highlight
    var selecting: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            if selecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? Chalk.yellow : Chalk.dust)
                    .transition(.scale.combined(with: .opacity))
            }

            ClipThumbnail(url: clip.url)
                .frame(width: 108, height: 61)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(selecting ? 0.4 : 0.9))
                        .shadow(radius: 3)
                )
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Chalk.chalk.opacity(0.18), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                if clip.isPractice {
                    Text("Practice clip")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Chalk.chalk)
                    Text(clip.createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Chalk.dust)
                } else {
                    Text(clip.scoreLine)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(Chalk.chalk)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(clip.period)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Chalk.yellow)
                        Text(clip.clockTime)
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(Chalk.dust)
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(isSelected ? Chalk.yellow.opacity(0.8) : Chalk.chalk.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1))
    }
}

