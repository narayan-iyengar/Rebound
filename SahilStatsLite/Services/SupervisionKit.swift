//
//  SupervisionKit.swift
//  SahilStatsLite
//
//  PURPOSE: Swift ports of the pieces of Roboflow `supervision` (MIT) that Rebound
//           actually needs, after the CV re-assessment (Aug 2026):
//             • PolygonZone — point-in-polygon "is this detection inside a region?"
//               The rim-ROI primitive for §16 rim-region shot detection.
//             • LineZone    — directed-line crossing counter (ball crosses the rim
//               plane; players cross half-court). In/out counts.
//             • DetectionsSmoother — per-track temporal box moving-average (utility;
//               NOT wired into the live path — DeepTracker/AutoZoomManager already
//               smooth via Kalman + observation momentum + hold + SmoothZoom, so a
//               second smoother would be redundant. Kept for future ROI-scale use).
//
//  NOTE on ByteTrack: supervision's ByteTrack + OC-SORT are ALREADY implemented in
//  DeepTracker.swift (two-stage low-conf re-matching, velocity consistency, Re-ID),
//  and §17 foreground-occlusion robustness already lives in AutoZoomManager. So the
//  only genuinely-new supervision port needed is the zone geometry above. See the
//  design doc §14 (2026-08-25 entry).
//
//  COORDINATES: all APIs take normalized points/rects in the app's AI-frame space
//  (0…1, Vision convention y=0 at the BOTTOM). Callers stay in one space.
//
//  KEY TYPES: PolygonZone, LineZone, DetectionsSmoother
//
//  NOTE: Keep this header updated when modifying this file.
//

import CoreGraphics

// MARK: - PolygonZone

/// A closed polygon region. Ask whether points (e.g. a detection anchor — the
/// bottom-center of a box, or a ball centroid) fall inside it. The rim-ROI is a
/// small quad/rectangle around each hoop; "an orange thing entered the rim zone"
/// becomes `zone.contains(ballCentroid)`.
struct PolygonZone: Equatable {
    /// Polygon vertices in order (implicitly closed). ≥3 for a real region.
    let vertices: [CGPoint]

    init(_ vertices: [CGPoint]) { self.vertices = vertices }

    /// Axis-aligned rectangle convenience (rim ROI is usually a box).
    init(rect: CGRect) {
        self.vertices = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    /// Point-in-polygon via ray casting (even–odd rule). Points exactly on an edge
    /// are treated as inside deterministically enough for gating; this is not meant
    /// for exact boundary classification.
    func contains(_ p: CGPoint) -> Bool {
        guard vertices.count >= 3 else { return false }
        var inside = false
        var j = vertices.count - 1
        for i in 0..<vertices.count {
            let vi = vertices[i], vj = vertices[j]
            if (vi.y > p.y) != (vj.y > p.y) {
                let slope = (p.y - vi.y) / (vj.y - vi.y)
                let xCross = vi.x + slope * (vj.x - vi.x)
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// How many of the given anchor points fall inside the zone.
    func triggerCount(_ points: [CGPoint]) -> Int {
        points.reduce(0) { $0 + (contains($1) ? 1 : 0) }
    }

    /// The zone's bounding box (handy for cropping the rim ROI out of a frame).
    var boundingBox: CGRect {
        guard let first = vertices.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for v in vertices.dropFirst() {
            minX = min(minX, v.x); minY = min(minY, v.y)
            maxX = max(maxX, v.x); maxY = max(maxY, v.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - LineZone

/// A directed line segment that counts objects crossing it, by tracker id. Supervision's
/// LineZone: each tracked point is assigned a side of the directed line; a change of
/// side between frames is a crossing. Direction gives in vs out (e.g. ball crossing
/// DOWN through the rim plane = a scoring-side crossing).
final class LineZone {
    let start: CGPoint
    let end: CGPoint

    private(set) var inCount = 0
    private(set) var outCount = 0
    private var lastSide: [Int: Bool] = [:]   // trackId -> side (true = left of A→B)

    init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    /// Which side of the directed line A→B the point is on (true = left / positive cross).
    private func side(of p: CGPoint) -> Bool {
        let cross = (end.x - start.x) * (p.y - start.y) - (end.y - start.y) * (p.x - start.x)
        return cross > 0
    }

    /// Feed the current tracked anchor points. Returns the (in, out) crossings THIS call.
    @discardableResult
    func update(_ tracked: [(id: Int, point: CGPoint)]) -> (inDelta: Int, outDelta: Int) {
        var inDelta = 0, outDelta = 0
        let live = Set(tracked.map { $0.id })
        lastSide = lastSide.filter { live.contains($0.key) }  // forget departed tracks

        for t in tracked {
            let s = side(of: t.point)
            if let prev = lastSide[t.id], prev != s {
                // Crossed. left→right (true→false) counts as "in", the reverse as "out".
                if prev { inCount += 1; inDelta += 1 } else { outCount += 1; outDelta += 1 }
            }
            lastSide[t.id] = s
        }
        return (inDelta, outDelta)
    }

    func reset() {
        inCount = 0; outCount = 0; lastSide.removeAll()
    }
}

// MARK: - DetectionsSmoother  (utility — not wired into the live path)

/// Per-track temporal box smoother: averages each track's last `window` boxes to
/// damp jitter. Supervision's DetectionsSmoother. NOT currently used in Rebound's
/// live tracking (DeepTracker + AutoZoomManager already smooth heavily); kept for
/// future ROI-scale detection (e.g. steadying a small rim-region ball box).
final class DetectionsSmoother {
    private var history: [Int: [CGRect]] = [:]
    private let window: Int

    init(window: Int = 3) { self.window = max(1, window) }

    /// Smooth each track's box by the mean of its last `window` boxes.
    func smooth(_ boxes: [(id: Int, box: CGRect)]) -> [Int: CGRect] {
        let live = Set(boxes.map { $0.id })
        history = history.filter { live.contains($0.key) }

        var out: [Int: CGRect] = [:]
        for b in boxes {
            var h = history[b.id] ?? []
            h.append(b.box)
            if h.count > window { h.removeFirst() }
            history[b.id] = h
            out[b.id] = Self.mean(h)
        }
        return out
    }

    func reset() { history.removeAll() }

    static func mean(_ boxes: [CGRect]) -> CGRect {
        guard !boxes.isEmpty else { return .zero }
        let n = CGFloat(boxes.count)
        let x = boxes.reduce(0) { $0 + $1.minX } / n
        let y = boxes.reduce(0) { $0 + $1.minY } / n
        let w = boxes.reduce(0) { $0 + $1.width } / n
        let h = boxes.reduce(0) { $0 + $1.height } / n
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
