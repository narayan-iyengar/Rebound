//
//  WatchTheme.swift
//  SahilStatsLiteWatch
//
//  PURPOSE: Chalk palette for the Watch app — the phone's chalkboard look on an
//           OLED-dark green board (near-black for battery + legibility on the small
//           screen), with the same chalk accents. Mirrors Chalk in the phone target.
//  KEY TYPES: WChalk, .watchBoard()
//

import SwiftUI

enum WChalk {
    static let board  = Color(red: 0.075, green: 0.106, blue: 0.086)  // near-black green
    static let board2 = Color(red: 0.110, green: 0.157, blue: 0.129)
    static let chalk  = Color(red: 0.949, green: 0.937, blue: 0.894)
    static let chalkDim = Color(red: 0.804, green: 0.831, blue: 0.796)
    static let dust   = Color(red: 0.545, green: 0.604, blue: 0.565)
    static let yellow = Color(red: 0.945, green: 0.824, blue: 0.443)
    static let coral  = Color(red: 0.922, green: 0.557, blue: 0.451)
    static let sky    = Color(red: 0.663, green: 0.792, blue: 0.820)
    static let green  = Color(red: 0.663, green: 0.839, blue: 0.627)
}

private struct WatchBoard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [WChalk.board2, WChalk.board],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            )
    }
}

extension View {
    /// OLED-dark green chalkboard ground for a Watch screen.
    func watchBoard() -> some View { modifier(WatchBoard()) }
}
