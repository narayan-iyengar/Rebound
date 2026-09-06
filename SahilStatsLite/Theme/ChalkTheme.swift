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
//
// FONT ROLES (the accent rule — keeps the app polished, not childish):
//   The hand-chalk face (chalkScript / chalkHand) is an ACCENT, used ONLY on:
//     • the app wordmark (ReboundWordmark)
//     • primary screen titles + section headers ("New Game", "Career Stats",
//       "Game Log", …) and empty-state headlines ("No games scheduled")
//     • ChalkButton CTA labels (its title is an intentional accent)
//   EVERYTHING ELSE uses a clean SYSTEM font (with the Chalk COLOR tokens kept
//   for color): field labels, captions, hints, list-row text (opponent names,
//   dates), status pills/chips, toggle + picker labels, and all data/numbers.
//   System type scale: title-ish 17 semibold · body 15 regular/medium ·
//   label 13 medium · caption 12 regular. Muted = Chalk.dust, primary = Chalk.chalk;
//   keep semantic accent colors (yellow/coral/sky/green) where they carry meaning,
//   and monospacedDigit on numbers.

extension Font {
    /// Display face (headings, wordmark, big labels). Now Gochi Hand — its printed
    /// letterforms are far more legible than cursive Caveat (whose 'd' read as 'a'),
    /// so we use ONE chalk face everywhere. `weight` kept for call-site compatibility.
    static func chalkScript(_ size: CGFloat, weight: CGFloat = 640) -> Font {
        .custom(ChalkFonts.handFamily, size: size)
    }
    /// Gochi Hand — printed-chalk face. Labels, pills, team names, captions.
    static func chalkHand(_ size: CGFloat) -> Font {
        .custom(ChalkFonts.handFamily, size: size)
    }
}

// MARK: - Board background

/// Faint hand-drawn X's-and-O's play diagram — the chalkboard watermark behind
/// every board screen. Drawn in code (Canvas) so it's crisp at any size and needs
/// no bundled asset. Non-interactive and very low opacity so it never competes.
struct ChalkPlayBackdrop: View {
    var opacity: Double = 0.05

    var body: some View {
        Canvas { ctx, size in
            let shade = GraphicsContext.Shading.color(Chalk.chalk.opacity(opacity))
            let lw = max(1.6, size.width * 0.0045)
            let solid = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            let dashed = StrokeStyle(lineWidth: lw, lineCap: .round,
                                     dash: [size.width * 0.02, size.width * 0.016])

            let w = size.width, h = size.height
            let left = w * 0.09, right = w * 0.91
            let top = h * 0.30, bottom = h * 0.90
            let midX = (left + right) / 2
            let hoopY = bottom - h * 0.045

            func stroke(_ p: Path, _ style: StrokeStyle = solid) { ctx.stroke(p, with: shade, style: style) }

            // Court boundary
            stroke(Path(roundedRect: CGRect(x: left, y: top, width: right - left, height: bottom - top),
                        cornerRadius: w * 0.03))

            // Backboard + rim
            var bb = Path()
            bb.move(to: CGPoint(x: midX - w * 0.06, y: bottom - h * 0.03))
            bb.addLine(to: CGPoint(x: midX + w * 0.06, y: bottom - h * 0.03))
            stroke(bb)
            stroke(Path(ellipseIn: CGRect(x: midX - w * 0.018, y: hoopY - w * 0.018,
                                          width: w * 0.036, height: w * 0.036)))

            // Key + free-throw circle
            let keyW = w * 0.20, keyTop = bottom - h * 0.34
            stroke(Path(CGRect(x: midX - keyW / 2, y: keyTop, width: keyW, height: bottom - keyTop)))
            let ftR = w * 0.10
            stroke(Path(ellipseIn: CGRect(x: midX - ftR, y: keyTop - ftR, width: ftR * 2, height: ftR * 2)))

            // Three-point arc
            var tp = Path()
            tp.addArc(center: CGPoint(x: midX, y: hoopY), radius: (right - left) * 0.42,
                      startAngle: .degrees(197), endAngle: .degrees(343), clockwise: false)
            stroke(tp)

            // Players + motion — a simple set play
            func drawO(_ p: CGPoint) {
                let r = w * 0.022
                stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)))
            }
            func drawX(_ p: CGPoint) {
                let r = w * 0.019
                var pa = Path()
                pa.move(to: CGPoint(x: p.x - r, y: p.y - r)); pa.addLine(to: CGPoint(x: p.x + r, y: p.y + r))
                pa.move(to: CGPoint(x: p.x - r, y: p.y + r)); pa.addLine(to: CGPoint(x: p.x + r, y: p.y - r))
                stroke(pa)
            }
            func arrow(_ a: CGPoint, _ b: CGPoint) {
                var pa = Path(); pa.move(to: a); pa.addLine(to: b)
                stroke(pa, dashed)
                let ang = atan2(b.y - a.y, b.x - a.x), hl = w * 0.026
                var head = Path()
                head.move(to: b)
                head.addLine(to: CGPoint(x: b.x - hl * cos(ang - .pi / 7), y: b.y - hl * sin(ang - .pi / 7)))
                head.move(to: b)
                head.addLine(to: CGPoint(x: b.x - hl * cos(ang + .pi / 7), y: b.y - hl * sin(ang + .pi / 7)))
                stroke(head)
            }

            let o1 = CGPoint(x: midX, y: bottom - h * 0.16)          // ball handler
            let o2 = CGPoint(x: left + w * 0.11, y: bottom - h * 0.09) // left wing
            let o3 = CGPoint(x: right - w * 0.11, y: bottom - h * 0.09) // right wing
            drawO(o1); drawO(o2); drawO(o3)
            drawX(CGPoint(x: midX + w * 0.05, y: bottom - h * 0.23))
            drawX(CGPoint(x: left + w * 0.14, y: bottom - h * 0.16))
            arrow(o2, CGPoint(x: midX - w * 0.05, y: hoopY + h * 0.015))  // baseline cut
            arrow(o1, o3)                                                 // swing pass
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ChalkBoard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                LinearGradient(colors: [Chalk.board, Chalk.board2],
                               startPoint: .top, endPoint: .bottom)
                ChalkPlayBackdrop()
            }
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
            .background(Chalk.board2.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: Chalk.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: Chalk.cardCorner)
                    .strokeBorder(Chalk.chalk.opacity(0.30), lineWidth: 1.5)
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
    var body: some View {
        // The SF Symbol reads unmistakably as a basketball at any size.
        Image(systemName: "basketball.fill")
            .font(.system(size: size))
            .foregroundColor(color)
    }
}

// MARK: - Tally marks (chalk strokes, groups of 5 with a diagonal slash)
// Fouls/timeouts count up as tallies — no tournament-specific bonus logic; the
// scorekeeper reads the count against whatever rule is in effect.

struct TallyMarks: View {
    let count: Int
    var color: Color = Chalk.chalk
    var barHeight: CGFloat = 18

    private var groups: Int { max(1, (count + 4) / 5) }

    var body: some View {
        HStack(spacing: 9) {
            if count == 0 {
                // Empty placeholder so the row keeps its height / tap target.
                Rectangle().fill(color.opacity(0.25))
                    .frame(width: barHeight * 0.9, height: 2)
            } else {
                ForEach(0..<groups, id: \.self) { g in
                    TallyGroup(n: min(5, count - g * 5), color: color, barHeight: barHeight)
                }
            }
        }
    }
}

private struct TallyGroup: View {
    let n: Int
    var color: Color
    var barHeight: CGFloat
    private var bw: CGFloat { max(3, barHeight * 0.17) }   // thicker bars — easier to count at a glance
    var body: some View {
        ZStack {
            HStack(spacing: bw + 3) {                        // wider gaps so 1 vs 3 reads instantly
                ForEach(0..<min(n, 4), id: \.self) { _ in
                    Capsule().fill(color).frame(width: bw, height: barHeight)
                }
            }
            if n >= 5 {
                Capsule().fill(color)
                    .frame(width: bw, height: barHeight * 1.35)
                    .rotationEffect(.degrees(62))
            }
        }
    }
}

struct ReboundWordmark: View {
    var size: CGFloat = 44
    var color: Color = Chalk.chalk
    var body: some View {
        // Gochi Hand (printed) instead of cursive Caveat — the cursive "d" read as
        // "a" ("bouna"); printed letterforms are unambiguous for the wordmark.
        // The ball IS the "o" of Reb-O-und — so it reads "Rebound", not "Reobound".
        HStack(spacing: size * 0.04) {
            Text("Reb").font(.chalkHand(size)).foregroundColor(color)
            BasketballGlyph(size: size * 0.62)
                .padding(.horizontal, size * 0.01)
            Text("und").font(.chalkHand(size)).foregroundColor(color)
        }
        .fixedSize()
    }
}
