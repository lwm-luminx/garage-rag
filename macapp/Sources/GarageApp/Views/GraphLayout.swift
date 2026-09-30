import CoreGraphics
import Foundation

/// Where the Graph page draws each vertex of a neighbourhood: the center in the middle and every
/// other vertex on a ring for its hop distance, spread around the ring near the vertices it hangs off.
///
/// Deterministic, with no simulation to settle, so the same neighbourhood always looks the same and
/// a unit test can hold it. Pure geometry: it knows nothing about SwiftUI.
struct GraphLayout: Equatable {
    /// Each vertex's position, in the coordinates of the `size` given.
    let positions: [Int64: CGPoint]
    /// Each vertex's hop distance from the center; the center is 0.
    let rings: [Int64: Int]
    /// The center's position.
    let origin: CGPoint
    /// Hops from the center to the farthest vertex.
    let depth: Int

    /// The layout of `neighborhood` inside `size`, keeping `margin` points clear at every edge.
    ///
    /// A vertex no edge connects to the center (the walk has none, but a filter can leave one)
    /// is placed on the outermost ring.
    init(neighborhood: GraphNeighborhood, size: CGSize, margin: CGFloat = 32) {
        guard let center = neighborhood.center else {
            self.init(positions: [:], rings: [:], origin: CGPoint(x: size.width / 2, y: size.height / 2), depth: 0)
            return
        }
        let ids = Set(neighborhood.vertices.map(\.id))
        var neighbours: [Int64: [Int64]] = [:]
        for edge in neighborhood.edges where ids.contains(edge.sourceID) && ids.contains(edge.targetID) {
            neighbours[edge.sourceID, default: []].append(edge.targetID)
            neighbours[edge.targetID, default: []].append(edge.sourceID)
        }

        // Breadth first from the center gives each vertex its ring.
        var rings: [Int64: Int] = [center.id: 0]
        var frontier = [center.id]
        while !frontier.isEmpty {
            var next: [Int64] = []
            for id in frontier {
                for other in (neighbours[id] ?? []).sorted() where rings[other] == nil {
                    rings[other] = rings[id]! + 1
                    next.append(other)
                }
            }
            frontier = next
        }
        let reached = rings.values.max() ?? 0
        let strays = neighborhood.vertices.map(\.id).filter { rings[$0] == nil }
        let depth = strays.isEmpty ? reached : reached + 1
        for id in strays {
            rings[id] = depth
        }

        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = max(0, min(size.width, size.height) / 2 - margin)
        var positions: [Int64: CGPoint] = [center.id: origin]
        var angles: [Int64: CGFloat] = [center.id: 0]
        let titles = Dictionary(uniqueKeysWithValues: neighborhood.vertices.map { ($0.id, ($0.label, $0.title)) })

        for ring in stride(from: 1, through: depth, by: 1) {
            let members = rings.filter { $0.value == ring }.map(\.key)
            guard !members.isEmpty else { continue }
            // A vertex wants the angle of the ring-inward vertices it hangs off; the first ring, with
            // nothing inward but the center, is ordered by label then title so like sits with like.
            let preferred: [Int64: CGFloat] = Dictionary(uniqueKeysWithValues: members.map { id in
                let inward = (neighbours[id] ?? []).filter { rings[$0] == ring - 1 }.compactMap { angles[$0] }
                return (id, inward.isEmpty ? 0 : Self.meanAngle(inward))
            })
            let ordered: [Int64]
            if ring == 1 {
                ordered = members.sorted { a, b in
                    let (la, ta) = titles[a] ?? ("", "")
                    let (lb, tb) = titles[b] ?? ("", "")
                    return la == lb ? (ta == tb ? a < b : ta < tb) : la < lb
                }
            } else {
                ordered = members.sorted { a, b in
                    preferred[a]! == preferred[b]! ? a < b : preferred[a]! < preferred[b]!
                }
            }
            // The first ring is spaced evenly from the top. Farther rings keep each vertex at its
            // preferred angle, on its parent's side of the picture, pushed apart where they collide.
            let placed: [CGFloat] = ring == 1
                ? Self.evenlySpaced(count: ordered.count, from: -CGFloat.pi / 2)
                : Self.spreadApart(ordered.map { preferred[$0]! })
            let ringRadius = radius * CGFloat(ring) / CGFloat(depth)
            for (index, id) in ordered.enumerated() {
                let angle = placed[index]
                angles[id] = angle
                positions[id] = CGPoint(x: origin.x + ringRadius * cos(angle), y: origin.y + ringRadius * sin(angle))
            }
        }
        self.init(positions: positions, rings: rings, origin: origin, depth: depth)
    }

    private init(positions: [Int64: CGPoint], rings: [Int64: Int], origin: CGPoint, depth: Int) {
        self.positions = positions
        self.rings = rings
        self.origin = origin
        self.depth = depth
    }

    /// The vertex whose drawn circle of `radius` is under `point`, nearest first.
    func vertex(at point: CGPoint, radius: CGFloat) -> Int64? {
        var best: (id: Int64, distance: CGFloat)?
        for (id, position) in positions {
            let distance = hypot(position.x - point.x, position.y - point.y)
            if distance <= radius, best == nil || distance < best!.distance {
                best = (id, distance)
            }
        }
        return best?.id
    }

    /// `count` angles a full turn apart from each other, the first at `start`.
    static func evenlySpaced(count: Int, from start: CGFloat) -> [CGFloat] {
        guard count > 0 else { return [] }
        let step = 2 * CGFloat.pi / CGFloat(count)
        return (0..<count).map { start + step * CGFloat($0) }
    }

    /// Angles as near their preferred values (given in ascending order) as a minimum separation
    /// allows: neighbours that collide are pushed apart, the whole group is re-centred on where it
    /// wanted to be, and a ring too crowded for that falls back to even spacing.
    ///
    /// The separation is a full turn over the count, and never more than `maxSeparation`, so a
    /// ring of few vertices does not scatter them to opposite sides.
    static func spreadApart(_ preferred: [CGFloat], maxSeparation: CGFloat = .pi / 6) -> [CGFloat] {
        guard preferred.count > 1 else { return preferred }
        let separation = min(2 * CGFloat.pi / CGFloat(preferred.count), maxSeparation)
        var angles = preferred
        for i in 1..<angles.count {
            angles[i] = max(angles[i], angles[i - 1] + separation)
        }
        let drift = zip(angles, preferred).reduce(0) { $0 + ($1.0 - $1.1) } / CGFloat(angles.count)
        angles = angles.map { $0 - drift }
        if angles[angles.count - 1] - angles[0] >= 2 * CGFloat.pi - separation - 0.0001 {
            return evenlySpaced(count: preferred.count, from: preferred[0])
        }
        return angles
    }

    /// The circular mean of angles, so angles either side of the wrap average to the wrap, not to
    /// the opposite side.
    static func meanAngle(_ angles: [CGFloat]) -> CGFloat {
        let x = angles.reduce(0) { $0 + cos($1) }
        let y = angles.reduce(0) { $0 + sin($1) }
        return atan2(y, x)
    }
}
