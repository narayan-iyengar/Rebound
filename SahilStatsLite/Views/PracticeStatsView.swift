//
//  PracticeStatsView.swift
//  SahilStatsLite
//
//  PURPOSE: The Practice tab — one tab, three modes (Shooting · Workout · Clips).
//           Shooting: a month calendar to log at-home shooting (made/attempts per shot
//           type in a day-entry sheet), a half-court shot map with a dot per shot type
//           colored hot/cold by all-time %, and a per-dot trend sheet. Workout + Clips
//           are stubs for now (Clips launches the existing practice recorder).
//  KEY TYPES: PracticeStatsView, PracticeShootingStore, ShotKind, ShotDay
//  DEPENDS ON: AppState (Clips), Charts
//
//  NOTE: Keep this header updated when modifying this file.
//

import SwiftUI
import Charts
import Combine

// MARK: - Model

enum ShotKind: String, CaseIterable, Codable, Identifiable {
    case layup = "Layups", mid = "Mid-range", three = "3-pointers", ft = "Free throws"
    var id: String { rawValue }
    var short: String {
        switch self { case .layup: return "LAY"; case .mid: return "MID"; case .three: return "3PT"; case .ft: return "FT" }
    }
    /// Normalized position on the half court (x, y with y=0 at the baseline/hoop).
    var pos: CGPoint {
        switch self {
        case .layup: return CGPoint(x: 0.50, y: 0.16)
        case .ft:    return CGPoint(x: 0.50, y: 0.44)
        case .mid:   return CGPoint(x: 0.24, y: 0.56)
        case .three: return CGPoint(x: 0.50, y: 0.80)
        }
    }
}

struct ShotDay: Codable, Identifiable {
    var dateKey: String            // "yyyy-MM-dd"
    var date: Date
    var made: [String: Int] = [:]  // ShotKind.rawValue -> made
    var att: [String: Int] = [:]
    var id: String { dateKey }
    var totalAtt: Int { att.values.reduce(0, +) }
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

    func save(date: Date, made: [ShotKind: Int], att: [ShotKind: Int]) {
        let k = Self.dateKey(date)
        var m: [String: Int] = [:], a: [String: Int] = [:]
        for kind in ShotKind.allCases {
            let mv = max(0, made[kind] ?? 0), av = max(mv, att[kind] ?? 0)
            if av > 0 { m[kind.rawValue] = mv; a[kind.rawValue] = av }
        }
        if a.isEmpty { days[k] = nil } else { days[k] = ShotDay(dateKey: k, date: date, made: m, att: a) }
        persist()
    }

    /// All-time made/attempts for a shot kind.
    func total(_ kind: ShotKind) -> (made: Int, att: Int) {
        var m = 0, a = 0
        for d in days.values { m += d.made[kind.rawValue] ?? 0; a += d.att[kind.rawValue] ?? 0 }
        return (m, a)
    }
    func pct(_ kind: ShotKind) -> Double? {
        let t = total(kind); return t.att > 0 ? Double(t.made) / Double(t.att) * 100 : nil
    }
    /// Overall field goal % (everything except FT).
    var fgPct: Double? {
        var m = 0, a = 0
        for kind in [ShotKind.layup, .mid, .three] { let t = total(kind); m += t.made; a += t.att }
        return a > 0 ? Double(m) / Double(a) * 100 : nil
    }
    var ftPct: Double? { pct(.ft) }

    /// Per-session (per logged day) % for one kind, oldest first.
    func trend(_ kind: ShotKind) -> [(date: Date, pct: Double)] {
        days.values
            .filter { ($0.att[kind.rawValue] ?? 0) > 0 }
            .sorted { $0.date < $1.date }
            .map { (($0.date), Double($0.made[kind.rawValue] ?? 0) / Double($0.att[kind.rawValue] ?? 1) * 100) }
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

// MARK: - Shot color

private func pctColor(_ pct: Double?) -> Color {
    guard let p = pct else { return Chalk.dust }
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
    @State private var trendKind: ShotKind? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Practice").font(.chalkScript(30)).foregroundColor(Chalk.chalk)
                Spacer()
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)

            // Mode switcher
            HStack(spacing: 0) {
                ForEach(Mode.allCases) { m in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { mode = m } } label: {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(mode == m ? Chalk.yellow : Color.clear, in: Capsule())
                            .foregroundColor(mode == m ? Chalk.board : Chalk.chalkDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Chalk.board2, in: Capsule())
            .padding(.horizontal)
            .padding(.bottom, 8)

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
        .sheet(item: $trendKind) { kind in
            ShotTrendSheet(kind: kind)
        }
    }

    private struct IdentifiableDate: Identifiable { let date: Date; var id: String { PracticeShootingStore.dateKey(date) } }

    // MARK: Shooting mode

    private var shootingContent: some View {
        VStack(spacing: 16) {
            calendarCard
            shotMapCard
        }
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
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: 38)
                    }
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
                Text("\(n)")
                    .font(.system(size: 13, weight: isToday ? .heavy : .regular))
                    .foregroundColor(isToday ? Chalk.yellow : Chalk.chalk)
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
            ShotMap(store: store) { kind in trendKind = kind }
                .frame(height: 220)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("FG \(pctText(store.fgPct)) · FT \(pctText(store.ftPct))")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(Chalk.crisp)
                Spacer()
                Text("\(store.days.count) session\(store.days.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundColor(Chalk.dust)
            }
        }
        .padding(14)
        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Chalk.chalk.opacity(0.15), lineWidth: 1))
    }

    // MARK: Clips mode

    private var clipsContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundColor(Chalk.coral.opacity(0.85))
            Text("Practice clips").font(.chalkScript(26)).foregroundColor(Chalk.chalk)
            Text("Record and save highlight clips while he practices — same clip button, no game needed.")
                .font(.system(size: 14)).foregroundColor(Chalk.dust).multilineTextAlignment(.center).padding(.horizontal, 16)
            ChalkButton(title: "Start recording", icon: "record.circle", color: Chalk.coral, filled: true) {
                appState.startPractice()
            }
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

    // MARK: helpers

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: month)
    }
    private func pctText(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }

    /// Days of the visible month, padded with nils for the leading weekday offset.
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

// MARK: - Shot map (half court + dots)

private struct ShotMap: View {
    @ObservedObject var store: PracticeShootingStore
    let onTap: (ShotKind) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // Court lines
                Path { p in
                    p.move(to: CGPoint(x: w * 0.07, y: h * 0.09)); p.addLine(to: CGPoint(x: w * 0.93, y: h * 0.09)) // baseline
                    p.addRect(CGRect(x: w * 0.40, y: h * 0.09, width: w * 0.20, height: h * 0.34)) // key
                    p.addEllipse(in: CGRect(x: w * 0.40, y: h * 0.33, width: w * 0.20, height: h * 0.20)) // ft circle
                }
                .stroke(Chalk.dust.opacity(0.45), lineWidth: 1.3)
                Path { p in
                    p.move(to: CGPoint(x: w * 0.14, y: h * 0.09)); p.addLine(to: CGPoint(x: w * 0.14, y: h * 0.34))
                    p.addQuadCurve(to: CGPoint(x: w * 0.86, y: h * 0.34), control: CGPoint(x: w * 0.5, y: h * 0.95))
                    p.addLine(to: CGPoint(x: w * 0.86, y: h * 0.09))
                }
                .stroke(Chalk.dust.opacity(0.45), lineWidth: 1.3)
                Circle().stroke(Chalk.coral, lineWidth: 2).frame(width: 10, height: 10)
                    .position(x: w * 0.5, y: h * 0.13)

                ForEach(ShotKind.allCases) { kind in
                    dot(kind, at: CGPoint(x: kind.pos.x * w, y: h * 0.09 + kind.pos.y * h * 0.9))
                }
            }
        }
    }

    private func dot(_ kind: ShotKind, at pt: CGPoint) -> some View {
        let pct = store.pct(kind)
        let color = pctColor(pct)
        return Button { onTap(kind) } label: {
            ZStack {
                Circle().fill(color.opacity(0.25)).frame(width: 34, height: 34)
                    .modifier(Pulse())
                Circle().fill(color).frame(width: 15, height: 15)
                VStack(spacing: 0) {
                    Text(kind.short).font(.system(size: 8, weight: .heavy)).foregroundColor(Chalk.chalk)
                    Text(pct.map { "\(Int($0.rounded()))%" } ?? "–").font(.system(size: 9, weight: .bold)).foregroundColor(color)
                }
                .offset(y: 26)
            }
        }
        .buttonStyle(.plain)
        .position(pt)
    }
}

private struct Pulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1.15 : 0.85).opacity(on ? 1 : 0.55)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Entry sheet

private struct ShootingEntrySheet: View {
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PracticeShootingStore.shared
    @State private var made: [ShotKind: Int] = [:]
    @State private var att: [ShotKind: Int] = [:]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ShotKind.allCases) { kind in
                        HStack {
                            Text(kind.rawValue).font(.system(size: 15, weight: .medium)).foregroundColor(Chalk.chalk)
                            Spacer()
                            stepper("made", made[kind] ?? 0, Chalk.green) { made[kind] = max(0, $0); if (att[kind] ?? 0) < (made[kind] ?? 0) { att[kind] = made[kind] } }
                            Text("/").foregroundColor(Chalk.dust)
                            stepper("att", att[kind] ?? 0, Chalk.chalkDim) { att[kind] = max(made[kind] ?? 0, $0) }
                        }
                        .padding(12)
                        .background(Chalk.board2, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .chalkBoard()
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.save(date: date, made: made, att: att); dismiss() }
                }
            }
        }
        .onAppear {
            if let d = store.day(for: date) {
                for kind in ShotKind.allCases {
                    made[kind] = d.made[kind.rawValue] ?? 0
                    att[kind] = d.att[kind.rawValue] ?? 0
                }
            }
        }
    }

    private var titleText: String {
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: date)
    }

    private func stepper(_ label: String, _ value: Int, _ color: Color, _ set: @escaping (Int) -> Void) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Button { set(value - 1) } label: { Image(systemName: "minus").font(.system(size: 12, weight: .bold)).foregroundColor(Chalk.coral).frame(width: 26, height: 26).background(Color.black.opacity(0.25), in: Circle()) }.buttonStyle(.plain)
                Text("\(value)").font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundColor(color).frame(width: 30)
                Button { set(value + 1) } label: { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundColor(Chalk.green).frame(width: 26, height: 26).background(Color.black.opacity(0.25), in: Circle()) }.buttonStyle(.plain)
            }
            Text(label).font(.system(size: 9)).foregroundColor(Chalk.dust)
        }
    }
}

// MARK: - Trend sheet

private struct ShotTrendSheet: View {
    let kind: ShotKind
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PracticeShootingStore.shared

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                let t = store.total(kind)
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(store.pct(kind).map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 46, weight: .heavy)).foregroundColor(pctColor(store.pct(kind)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(kind.rawValue).font(.system(size: 15, weight: .semibold)).foregroundColor(Chalk.chalk)
                        Text("\(t.made) / \(t.att) all-time").font(.system(size: 12)).foregroundColor(Chalk.dust)
                    }
                    Spacer()
                }

                let data = store.trend(kind)
                if data.count > 1 {
                    Chart {
                        ForEach(Array(data.enumerated()), id: \.offset) { i, pt in
                            LineMark(x: .value("Session", i), y: .value("%", pt.pct))
                                .foregroundStyle(pctColor(store.pct(kind)))
                                .lineStyle(StrokeStyle(lineWidth: 2.6, lineJoin: .round)).interpolationMethod(.catmullRom)
                            PointMark(x: .value("Session", i), y: .value("%", pt.pct))
                                .foregroundStyle(pctColor(store.pct(kind))).symbolSize(24)
                        }
                    }
                    .frame(height: 200)
                    .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Chalk.dust.opacity(0.2)); AxisValueLabel().foregroundStyle(Chalk.dust) } }
                    .chartXAxis(.hidden)
                    Text("% per session (oldest → newest)").font(.system(size: 11)).foregroundColor(Chalk.dust)
                } else {
                    Text("Log a few sessions and the trend shows up here.")
                        .font(.system(size: 14)).foregroundColor(Chalk.dust).padding(.top, 20)
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .chalkBoard()
            .navigationTitle("Trend").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
