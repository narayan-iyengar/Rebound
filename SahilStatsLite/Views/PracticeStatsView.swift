//
//  PracticeStatsView.swift
//  SahilStatsLite
//
//  PURPOSE: The Practice tab — one tab, three modes (Shooting · Workout · Clips).
//           Shooting: a month calendar to log at-home shooting (made/attempts per SPOT
//           in a day-entry sheet — 5 two-point spots, 5 three-point spots, plus the free
//           throw), a half-court shot map with a pulsing dot per spot colored hot/cold by
//           all-time %, and a per-spot trend sheet. Workout + Clips are stubs (Clips
//           launches the existing practice recorder).
//  KEY TYPES: PracticeStatsView, PracticeShootingStore, ShotSpot, ShotDay
//  DEPENDS ON: AppState (Clips), Charts
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Charts
import Combine

// MARK: - Model

enum ShotRange { case two, three, ft }

enum ShotSpot: String, CaseIterable, Codable, Identifiable {
    // 2-pointers
    case rim = "Layup / rim"
    case leftBaseline2 = "Left baseline"
    case rightBaseline2 = "Right baseline"
    case leftElbow2 = "Left elbow"
    case rightElbow2 = "Right elbow"
    // 3-pointers
    case leftCorner3 = "Left corner 3"
    case rightCorner3 = "Right corner 3"
    case leftWing3 = "Left wing 3"
    case rightWing3 = "Right wing 3"
    case top3 = "Top 3"
    // Free throw
    case ft = "Free throw"

    var id: String { rawValue }

    var range: ShotRange {
        switch self {
        case .rim, .leftBaseline2, .rightBaseline2, .leftElbow2, .rightElbow2: return .two
        case .leftCorner3, .rightCorner3, .leftWing3, .rightWing3, .top3: return .three
        case .ft: return .ft
        }
    }

    /// Normalized position on the half court (x, y each 0…1 of the map's frame).
    var pos: CGPoint {
        switch self {
        case .rim:            return CGPoint(x: 0.50, y: 0.17)
        case .leftBaseline2:  return CGPoint(x: 0.30, y: 0.14)
        case .rightBaseline2: return CGPoint(x: 0.70, y: 0.14)
        case .leftElbow2:     return CGPoint(x: 0.38, y: 0.34)
        case .rightElbow2:    return CGPoint(x: 0.62, y: 0.34)
        case .leftCorner3:    return CGPoint(x: 0.09, y: 0.13)
        case .rightCorner3:   return CGPoint(x: 0.91, y: 0.13)
        case .leftWing3:      return CGPoint(x: 0.14, y: 0.46)
        case .rightWing3:     return CGPoint(x: 0.86, y: 0.46)
        case .top3:           return CGPoint(x: 0.50, y: 0.62)
        case .ft:             return CGPoint(x: 0.50, y: 0.30)
        }
    }
}

struct ShotDay: Codable, Identifiable {
    var dateKey: String            // "yyyy-MM-dd"
    var date: Date
    var made: [String: Int] = [:]  // ShotSpot.rawValue -> made
    var att: [String: Int] = [:]
    var id: String { dateKey }
}

@MainActor
final class PracticeShootingStore: ObservableObject {
    static let shared = PracticeShootingStore()
    @Published private(set) var days: [String: ShotDay] = [:]
    private let key = "practiceShootingLogs"

    private init() { load() }

    static func dateKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }

    func day(for date: Date) -> ShotDay? { days[Self.dateKey(date)] }

    func save(date: Date, made: [ShotSpot: Int], att: [ShotSpot: Int]) {
        let k = Self.dateKey(date)
        var m: [String: Int] = [:], a: [String: Int] = [:]
        for spot in ShotSpot.allCases {
            let mv = max(0, made[spot] ?? 0), av = max(mv, att[spot] ?? 0)
            if av > 0 { m[spot.rawValue] = mv; a[spot.rawValue] = av }
        }
        if a.isEmpty { days[k] = nil } else { days[k] = ShotDay(dateKey: k, date: date, made: m, att: a) }
        persist()
    }

    func total(_ spot: ShotSpot) -> (made: Int, att: Int) {
        var m = 0, a = 0
        for d in days.values { m += d.made[spot.rawValue] ?? 0; a += d.att[spot.rawValue] ?? 0 }
        return (m, a)
    }
    func pct(_ spot: ShotSpot) -> Double? {
        let t = total(spot); return t.att > 0 ? Double(t.made) / Double(t.att) * 100 : nil
    }
    /// Combined % for a whole range (all 2s, all 3s).
    func pct(range: ShotRange) -> Double? {
        var m = 0, a = 0
        for spot in ShotSpot.allCases where spot.range == range { let t = total(spot); m += t.made; a += t.att }
        return a > 0 ? Double(m) / Double(a) * 100 : nil
    }
    var fgPct: Double? {
        var m = 0, a = 0
        for spot in ShotSpot.allCases where spot.range != .ft { let t = total(spot); m += t.made; a += t.att }
        return a > 0 ? Double(m) / Double(a) * 100 : nil
    }
    var ftPct: Double? { pct(.ft) }

    /// Per-session (per logged day) % for one spot, oldest first.
    func trend(_ spot: ShotSpot) -> [(date: Date, pct: Double)] {
        days.values
            .filter { ($0.att[spot.rawValue] ?? 0) > 0 }
            .sorted { $0.date < $1.date }
            .map { (($0.date), Double($0.made[spot.rawValue] ?? 0) / Double($0.att[spot.rawValue] ?? 1) * 100) }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let arr = try? JSONDecoder().decode([ShotDay].self, from: data) else { return }
        days = Dictionary(uniqueKeysWithValues: arr.map { ($0.dateKey, $0) })
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(Array(days.values)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

private func pctColor(_ pct: Double?) -> Color {
    guard let p = pct else { return Chalk.dust.opacity(0.6) }
    if p >= 55 { return Chalk.green }
    if p >= 38 { return Chalk.yellow }
    return Chalk.coral
}

// MARK: - Practice tab

struct PracticeStatsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var store = PracticeShootingStore.shared

    enum Mode: String, CaseIterable, Identifiable { case shooting = "Shooting", workout = "Workout", clips = "Clips"; var id: String { rawValue } }
    @State private var mode: Mode = .shooting

    @State private var month = Date()
    @State private var entryDate: Date? = nil
    @State private var trendSpot: ShotSpot? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Practice").font(.chalkScript(30)).foregroundColor(Chalk.chalk)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

            HStack(spacing: 0) {
                ForEach(Mode.allCases) { m in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { mode = m } } label: {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(mode == m ? Chalk.yellow : Color.clear, in: Capsule())
                            .foregroundColor(mode == m ? Chalk.board : Chalk.chalkDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4).background(Chalk.board2, in: Capsule())
            .padding(.horizontal).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 16) {
                    switch mode {
                    case .shooting: shootingContent
                    case .workout: comingSoon("Workout", "Log coach-assigned reps and time — pushups, sprints, plank — right here. Coming next.")
                    case .clips: clipsContent
                    }
                }
                .padding()
            }
        }
        .chalkBoard()
        .sheet(item: Binding(get: { entryDate.map { IdentifiableDate(date: $0) } },
                             set: { entryDate = $0?.date })) { wrap in
            ShootingEntrySheet(date: wrap.date)
        }
        .sheet(item: $trendSpot) { spot in ShotTrendSheet(spot: spot) }
    }

    private struct IdentifiableDate: Identifiable { let date: Date; var id: String { PracticeShootingStore.dateKey(date) } }

    private var shootingContent: some View {
        VStack(spacing: 16) { calendarCard; shotMapCard }
    }

    private var calendarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).foregroundColor(Chalk.dust)
                }
                Spacer()
                Text(monthTitle).font(.system(size: 15, weight: .semibold)).foregroundColor(Chalk.chalk)
                Spacer()
                Button { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month } label: {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundColor(Chalk.dust)
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: cols, spacing: 4) {
                ForEach(["S", "M", "T", "W", "T", "F", "S"], id: \.self) { d in
                    Text(d).font(.system(size: 10)).foregroundColor(Chalk.dust)
                }
                ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                    if let day { dayCell(day) } else { Color.clear.frame(height: 38) }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(Chalk.yellow).frame(width: 6, height: 6)
                Text("logged day").font(.system(size: 10)).foregroundColor(Chalk.dust)
            }
        }
        .padding(14)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    private func dayCell(_ day: Date) -> some View {
        let logged = store.day(for: day) != nil
        let isToday = Calendar.current.isDateInToday(day)
        let n = Calendar.current.component(.day, from: day)
        return Button { entryDate = day } label: {
            VStack(spacing: 2) {
                Text("\(n)").font(.system(size: 13, weight: isToday ? .heavy : .regular)).foregroundColor(isToday ? Chalk.yellow : Chalk.chalk)
                Circle().fill(logged ? Chalk.yellow : Color.clear).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(isToday ? Chalk.yellow.opacity(0.12) : Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var shotMapCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Shot map").font(.chalkScript(20)).foregroundColor(Chalk.chalk)
                Rectangle().fill(Chalk.chalk.opacity(0.12)).frame(height: 1)
                Text("tap a spot").font(.system(size: 11)).foregroundColor(Chalk.dust)
            }
            ShotMap(store: store) { spot in trendSpot = spot }
                .frame(height: 260)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("FG \(pctText(store.fgPct)) · 3PT \(pctText(store.pct(range: .three))) · FT \(pctText(store.ftPct))")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(Chalk.crisp)
                Spacer()
                Text("\(store.days.count) session\(store.days.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundColor(Chalk.dust)
            }
        }
        .padding(14)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    private var clipsContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundColor(Chalk.coral.opacity(0.85))
            Text("Practice clips").font(.chalkScript(26)).foregroundColor(Chalk.chalk)
            Text("Record and save highlight clips while he practices — same clip button, no game needed.")
                .font(.system(size: 14)).foregroundColor(Chalk.dust).multilineTextAlignment(.center).padding(.horizontal, 16)
            ChalkButton(title: "Start recording", icon: "record.circle", color: Chalk.coral, filled: true) { appState.startPractice() }
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    private func comingSoon(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.strengthtraining.traditional").font(.system(size: 40)).foregroundColor(Chalk.sky)
            Text(title).font(.chalkScript(26)).foregroundColor(Chalk.chalk)
            Text(sub).font(.system(size: 14)).foregroundColor(Chalk.dust).multilineTextAlignment(.center).padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    private var monthTitle: String { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: month) }
    private func pctText(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

    private var monthDays: [Date?] {
        let cal = Calendar.current
        guard let interval = cal.dateInterval(of: .month, for: month),
              let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let first = interval.start
        let lead = cal.component(.weekday, from: first) - 1
        var out: [Date?] = Array(repeating: nil, count: lead)
        for d in range { out.append(cal.date(byAdding: .day, value: d - 1, to: first)) }
        return out
    }
}

// MARK: - Shot map (half court + spot dots)

private struct ShotMap: View {
    @ObservedObject var store: PracticeShootingStore
    let onTap: (ShotSpot) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let topY = h * 0.06
            let hoop = CGPoint(x: w * 0.5, y: topY + h * 0.05)
            let ftY = topY + h * 0.30
            let keyW = w * 0.24
            let R = w * 0.42                 // 3-point radius (in x)
            ZStack {
                Path { p in
                    // baseline + backboard
                    p.move(to: CGPoint(x: w * 0.05, y: topY)); p.addLine(to: CGPoint(x: w * 0.95, y: topY))
                    p.move(to: CGPoint(x: w * 0.41, y: topY + 4)); p.addLine(to: CGPoint(x: w * 0.59, y: topY + 4))
                    // key + free-throw circle
                    p.addRect(CGRect(x: hoop.x - keyW / 2, y: topY, width: keyW, height: ftY - topY))
                    p.addEllipse(in: CGRect(x: hoop.x - keyW / 2, y: ftY - keyW / 2, width: keyW, height: keyW))
                    // restricted-area arc under the hoop
                    p.addArc(center: hoop, radius: w * 0.05, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                    // three-point line: two corner segments + a circular arc centered on the hoop
                    p.move(to: CGPoint(x: hoop.x - R, y: topY)); p.addLine(to: CGPoint(x: hoop.x - R, y: hoop.y))
                    p.move(to: CGPoint(x: hoop.x + R, y: topY)); p.addLine(to: CGPoint(x: hoop.x + R, y: hoop.y))
                    p.addArc(center: hoop, radius: R, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                }
                .stroke(Chalk.dust.opacity(0.4), lineWidth: 1.3)
                Circle().stroke(Chalk.coral, lineWidth: 2).frame(width: 9, height: 9).position(hoop)

                ForEach(Array(ShotSpot.allCases.enumerated()), id: \.element) { idx, spot in
                    dot(spot, delay: Double(idx) * 0.13, at: CGPoint(x: spot.pos.x * w, y: spot.pos.y * h))
                }
            }
        }
    }

    private func dot(_ spot: ShotSpot, delay: Double, at pt: CGPoint) -> some View {
        let pct = store.pct(spot)
        let color = pctColor(pct)
        return Button { onTap(spot) } label: {
            ZStack {
                Circle().fill(color.opacity(0.22)).frame(width: 26, height: 26).modifier(Pulse(delay: delay))
                Circle().fill(color).frame(width: 13, height: 13)
                if let pct {
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 8, weight: .heavy)).foregroundColor(Chalk.board)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .position(pt)
    }
}

private struct Pulse: ViewModifier {
    let delay: Double
    @State private var on = false
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1.2 : 0.85).opacity(on ? 0.9 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(delay)) { on = true }
            }
    }
}

// MARK: - Entry sheet

private struct ShootingEntrySheet: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PracticeShootingStore.shared
    @State private var made: [ShotSpot: Int] = [:]
    @State private var att: [ShotSpot: Int] = [:]

    private let twos: [ShotSpot] = [.rim, .leftBaseline2, .rightBaseline2, .leftElbow2, .rightElbow2]
    private let threes: [ShotSpot] = [.leftCorner3, .rightCorner3, .leftWing3, .rightWing3, .top3]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    section("2-POINTERS", twos)
                    section("3-POINTERS", threes)
                    section("FREE THROW", [.ft])
                }
                .padding()
            }
            .chalkBoard()
            .navigationTitle(titleText).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.save(date: date, made: made, att: att); dismiss() } }
            }
        }
        .onAppear {
            if let d = store.day(for: date) {
                for spot in ShotSpot.allCases { made[spot] = d.made[spot.rawValue] ?? 0; att[spot] = d.att[spot.rawValue] ?? 0 }
            }
        }
    }

    private func section(_ header: String, _ spots: [ShotSpot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header).font(.system(size: 11, weight: .heavy)).tracking(1).foregroundColor(Chalk.dust)
            ForEach(spots) { spot in
                HStack {
                    Text(spot.rawValue).font(.system(size: 14, weight: .medium)).foregroundColor(Chalk.chalk)
                    Spacer()
                    stepper(made[spot] ?? 0, Chalk.green) { made[spot] = max(0, $0); if (att[spot] ?? 0) < (made[spot] ?? 0) { att[spot] = made[spot] } }
                    Text("/").foregroundColor(Chalk.dust)
                    stepper(att[spot] ?? 0, Chalk.chalkDim) { att[spot] = max(made[spot] ?? 0, $0) }
                }
                .padding(10)
                .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var titleText: String { let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: date) }

    private func stepper(_ value: Int, _ color: Color, _ set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Button { set(value - 1) } label: { Image(systemName: "minus").font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.coral).frame(width: 24, height: 24).background(Color.black.opacity(0.25), in: Circle()) }.buttonStyle(.plain)
            Text("\(value)").font(.system(size: 17, weight: .bold)).monospacedDigit().foregroundColor(color).frame(width: 26)
            Button { set(value + 1) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundColor(Chalk.green).frame(width: 24, height: 24).background(Color.black.opacity(0.25), in: Circle()) }.buttonStyle(.plain)
        }
    }
}

// MARK: - Trend sheet

private struct ShotTrendSheet: View {
    let spot: ShotSpot
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PracticeShootingStore.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                let t = store.total(spot)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(store.pct(spot).map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 46, weight: .heavy)).foregroundColor(pctColor(store.pct(spot)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(spot.rawValue).font(.system(size: 15, weight: .semibold)).foregroundColor(Chalk.chalk)
                        Text("\(t.made) / \(t.att) all-time").font(.system(size: 12)).foregroundColor(Chalk.dust)
                    }
                    Spacer()
                }
                let data = store.trend(spot)
                if data.count > 1 {
                    Chart {
                        ForEach(Array(data.enumerated()), id: \.offset) { i, pt in
                            LineMark(x: .value("Session", i), y: .value("%", pt.pct))
                                .foregroundStyle(pctColor(store.pct(spot)))
                                .lineStyle(StrokeStyle(lineWidth: 2.6, lineJoin: .round)).interpolationMethod(.catmullRom)
                            PointMark(x: .value("Session", i), y: .value("%", pt.pct))
                                .foregroundStyle(pctColor(store.pct(spot))).symbolSize(24)
                        }
                    }
                    .frame(height: 200)
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Chalk.dust.opacity(0.2)); AxisValueLabel().foregroundStyle(Chalk.dust) } }
                    .chartXAxis(.hidden)
                    Text("% per session (oldest → newest)").font(.system(size: 11)).foregroundColor(Chalk.dust)
                } else {
                    Text("Log a few sessions from this spot and its trend shows up here.")
                        .font(.system(size: 14)).foregroundColor(Chalk.dust).padding(.top, 20)
                }
                Spacer()
            }
            .padding().frame(maxWidth: .infinity, alignment: .leading)
            .chalkBoard()
            .navigationTitle("Trend").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
