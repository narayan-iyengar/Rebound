//
//  ChalkTheme.swift
//  SahilStatsLite
//
//  PURPOSE: Shared "coach's chalkboard" visual system for Rebound. One small, quiet
//           API so every screen reads as the same board: colors, hand-chalk fonts,
//           and a handful of reusable chalk components. Design rule that runs through
//           everything: chalk for personality, CRISP for data (scores/clock/inputs
//           stay clean, high-contrast, tabular — legibility is sacred and burns into
//           video). Ground is green; over live video, chrome is dark + translucent.
//  KEY TYPES: Chalk (palette), Font.chalkScript/.chalkHand, .chalkBoard()/.chalkCard()/
//             .chalkPill()/.chalkPulse() view modifiers, ScoreText.
//  DEPENDS ON: SwiftUI only.
//
//  NOTE: Fonts (Caveat + Gochi Hand) are referenced by family name. Until the TTFs are
//        bundled + registered, Font.custom falls back to the system font gracefully —
//        the app always builds and runs.
//

import SwiftUI
import CoreText
import UIKit

// MARK: - Font registration (runtime, robust to Info.plist path quirks)

/// Registers the bundled hand-chalk TTFs at process scope so Font.custom resolves.
/// Confirmed family names (via the TTF `name` tables):
///   • Caveat-VariableFont_wght.ttf → family "Caveat"     (PostScript "Caveat-Regular")
///   • GochiHand-Regular.ttf        → family "Gochi Hand" (PostScript "GochiHand-Regular")
/// Caveat is a variable font; its default instance is weight 400 (Regular).
enum ChalkFonts {
    /// Font family names ChalkTheme's Font.chalkScript/.chalkHand resolve against.
    static let scriptFamily = "Caveat"
    static let handFamily   = "Gochi Hand"

    private static var didRegister = false

    static func register() {
        guard !didRegister else { return }
        didRegister = true

        for name in ["Caveat-VariableFont_wght", "GochiHand-Regular"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                debugPrint("🖍️ [ChalkFonts] MISSING font resource: \(name).ttf")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already-registered (e.g. via UIAppFonts) is expected and harmless.
                debugPrint("🖍️ [ChalkFonts] register note for \(name): \(error?.takeUnretainedValue().localizedDescription ?? "unknown")")
            }
        }

        // Confirm what actually resolved.
        let caveatOK = UIFont(name: scriptFamily, size: 20) != nil
        let gochiOK  = UIFont(name: handFamily,   size: 20) != nil
        debugPrint("🖍️ [ChalkFonts] Caveat resolved: \(caveatOK) | Gochi Hand resolved: \(gochiOK)")
    }
}

// MARK: - Palette (colored chalk on a green board)

enum Chalk {
    // Ground
    static let board   = Color(hex: 0x2C3A33)
    static let board2  = Color(hex: 0x26332D)
    // Ink
    static let chalk    = Color(hex: 0xF2EFE4)
    static let chalkDim = Color(hex: 0xCDD4CB)
    static let dust     = Color(hex: 0x93A399)
    // Accents (colored chalk) — also carry meaning: coral = live/hot, sky = our team,
    // yellow = attention/clock, green = go/success.
    static let yellow = Color(hex: 0xF1D271)
    static let coral  = Color(hex: 0xEB8E73)
    static let sky    = Color(hex: 0xA9CAD1)
    static let green  = Color(hex: 0xA9D6A0)
    // Data stays crisp.
    static let crisp = Color.white

    static let cardCorner: CGFloat = 14
}

extension Color {
    /// 0xRRGGBB literal → Color.
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Fonts (hand-chalk, with graceful system fallback)

extension Font {
    /// Caveat — the soft-chalk display face. Wordmark, headings, hints, big labels.
    /// Caveat is a VARIABLE font whose Font.custom default is wght=400 — thin and
    /// hard to read on device. Push the wght axis up (default ~640) for legibility.
    static func chalkScript(_ size: CGFloat, weight: CGFloat = 640) -> Font {
        let wghtAxis: Int = 0x77676874  // 'wght'
        if let base = UIFont(name: ChalkFonts.scriptFamily, size: size) {
            let desc = base.fontDescriptor.addingAttributes([
                .init(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight]
            ])
            return Font(UIFont(descriptor: desc, size: size))
        }
        return .custom(ChalkFonts.scriptFamily, size: size)
    }
    /// Gochi Hand — printed-chalk face. Labels, pills, team names, captions.
    /// Confirmed family name: "Gochi Hand".
    static func chalkHand(_ size: CGFloat) -> Font {
        .custom(ChalkFonts.handFamily, size: size)
    }
}

// MARK: - Board background

private struct ChalkBoard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            LinearGradient(colors: [Chalk.board, Chalk.board2],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}

// MARK: - Dashed chalk card

private struct ChalkCard: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.white.opacity(0.015),
                        in: RoundedRectangle(cornerRadius: Chalk.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Chalk.cardCorner)
                    .strokeBorder(Chalk.chalk.opacity(0.40),
                                  style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
    }
}

// MARK: - Chalk pill (solid-thin border, hand font)

private struct ChalkPill: ViewModifier {
    var color: Color = Chalk.chalkDim
    func body(content: Content) -> some View {
        content
            .font(.chalkHand(14))
            .foregroundColor(color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Chalk.board.opacity(0.35), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1.5))
    }
}

// MARK: - Subtle "breathe" for anything live (respects reduced motion)

private struct ChalkPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

extension View {
    /// Green chalkboard ground.
    func chalkBoard() -> some View { modifier(ChalkBoard()) }
    /// Dashed chalk-frame card.
    func chalkCard(padding: CGFloat = 14) -> some View { modifier(ChalkCard(padding: padding)) }
    /// Rounded chalk status/label pill.
    func chalkPill(_ color: Color = Chalk.chalkDim) -> some View { modifier(ChalkPill(color: color)) }
    /// Very subtle opacity breathe for live/active elements.
    func chalkPulse() -> some View { modifier(ChalkPulse()) }
}

// MARK: - Crisp data type (scores, clock — never chalk, always legible + tabular)

struct ScoreText: View {
    let value: String
    var size: CGFloat = 24
    var color: Color = Chalk.crisp
    var body: some View {
        Text(value)
            .font(.system(size: size, weight: .bold))
            .monospacedDigit()
            .foregroundColor(color)
    }
}

// MARK: - Chalk primary button

struct ChalkButton: View {
    let title: String
    var icon: String? = nil   // optional SF Symbol shown before the title
    var color: Color = Chalk.yellow
    var filled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.chalkHand(17))
                    .fontWeight(filled ? .bold : .regular)
            }
            .foregroundColor(filled ? Chalk.board : Chalk.chalk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(filled ? color : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(filled ? Color.clear : Chalk.chalk.opacity(0.4), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Basketball glyph + wordmark (the little ball between "Re" and "bound")

struct BasketballGlyph: View {
    var size: CGFloat = 22
    var color: Color = Chalk.coral
    private var lw: CGFloat { max(1.4, size * 0.085) }
    var body: some View {
        ZStack {
            Circle().stroke(color, lineWidth: lw)
            // seams, clipped inside the ball
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: 0)); p.addLine(to: CGPoint(x: size / 2, y: size))
                    p.move(to: CGPoint(x: 0, y: size / 2)); p.addLine(to: CGPoint(x: size, y: size / 2))
                }.stroke(color, lineWidth: lw * 0.85)
                Path { p in
                    p.addArc(center: CGPoint(x: -size * 0.18, y: size / 2), radius: size * 0.66,
                             startAngle: .degrees(-48), endAngle: .degrees(48), clockwise: false)
                }.stroke(color, lineWidth: lw * 0.85)
                Path { p in
                    p.addArc(center: CGPoint(x: size * 1.18, y: size / 2), radius: size * 0.66,
                             startAngle: .degrees(132), endAngle: .degrees(228), clockwise: false)
                }.stroke(color, lineWidth: lw * 0.85)
            }
            .clipShape(Circle().inset(by: lw / 2))
        }
        .frame(width: size, height: size)
    }
}

struct ReboundWordmark: View {
    var size: CGFloat = 46
    var color: Color = Chalk.chalk
    var body: some View {
        HStack(spacing: size * 0.02) {
            Text("Re").font(.chalkScript(size)).foregroundColor(color)
            BasketballGlyph(size: size * 0.5)
                .padding(.horizontal, size * 0.03)
                .offset(y: size * 0.06)
            Text("bound").font(.chalkScript(size)).foregroundColor(color)
        }
        .fixedSize()
    }
}
