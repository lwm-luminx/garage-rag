import XCTest
@testable import GarageApp

final class GraphLayoutTests: XCTestCase {

    private func vertex(_ id: Int64, _ label: String = "Fact", title: String = "") -> GraphVertexItem {
        GraphVertexItem(id: id, label: label, key: id, title: title.isEmpty ? "v\(id)" : title)
    }

    private func edge(_ id: Int64, _ source: Int64, _ target: Int64, _ label: String = "STATES") -> GraphEdgeItem {
        GraphEdgeItem(id: id, label: label, sourceID: source, targetID: target)
    }

    /// A thread with two messages, an author and a fact, and another document stating the fact two hops away.
    private var sample: GraphNeighborhood {
        GraphNeighborhood(
            available: true,
            center: vertex(1, "Document", title: "House"),
            vertices: [
                vertex(1, "Document", title: "House"),
                vertex(2, "Message", title: "[2026-09-24 18:02 UTC] Me: hi"),
                vertex(3, "Message", title: "[2026-09-24 18:03 UTC] Ada: hello"),
                vertex(4, "Author", title: "Ada"),
                vertex(5, "Fact", title: "The roof is slate."),
                vertex(7, "Document", title: "Barn"),
            ],
            edges: [
                edge(100, 1, 2, "HAS_MESSAGE"),
                edge(101, 1, 3, "HAS_MESSAGE"),
                edge(102, 4, 1, "WROTE"),
                edge(103, 1, 5, "STATES"),
                edge(105, 7, 5),
            ]
        )
    }

    private let size = CGSize(width: 400, height: 300)

    func testTheCenterSitsInTheMiddleAndRingsFollowHops() {
        let layout = GraphLayout(neighborhood: sample, size: size)
        XCTAssertEqual(layout.origin, CGPoint(x: 200, y: 150))
        XCTAssertEqual(layout.positions[1], layout.origin)
        XCTAssertEqual(layout.rings, [1: 0, 2: 1, 3: 1, 4: 1, 5: 1, 7: 2])
        XCTAssertEqual(layout.depth, 2)
    }

    func testRingRadiiShareTheAvailableSpace() {
        let layout = GraphLayout(neighborhood: sample, size: size, margin: 32)
        // Half the short side less the margin is the outer ring; the first ring is halfway out.
        let outer: CGFloat = 150 - 32
        for id: Int64 in [2, 3, 4, 5] {
            XCTAssertEqual(distance(layout.positions[id]!, layout.origin), outer / 2, accuracy: 0.001, "vertex \(id)")
        }
        XCTAssertEqual(distance(layout.positions[7]!, layout.origin), outer, accuracy: 0.001)
    }

    func testTheFirstRingIsEvenlySpacedWithLikeLabelsTogether() {
        let layout = GraphLayout(neighborhood: sample, size: size)
        // Sorted by label then title: Author, Fact, then the two messages; a quarter turn apart from the top.
        let angles = [4, 5, 2, 3].map { angle(layout.positions[$0]!, from: layout.origin) }
        XCTAssertEqual(angles[0], -.pi / 2, accuracy: 0.001)
        for i in 1..<angles.count {
            XCTAssertEqual(angles[i] - angles[i - 1], .pi / 2, accuracy: 0.001)
        }
    }

    func testASecondRingVertexSitsOnItsParentsSide() {
        let layout = GraphLayout(neighborhood: sample, size: size)
        // The only second-ring vertex hangs off the fact, so it takes that angle.
        XCTAssertEqual(
            angle(layout.positions[7]!, from: layout.origin),
            angle(layout.positions[5]!, from: layout.origin),
            accuracy: 0.001
        )
    }

    func testAVertexNoEdgeReachesGoesOnTheOutermostRing() {
        var vertices = sample.vertices
        vertices.append(vertex(9, "Author", title: "Nobody"))
        let stray = GraphNeighborhood(available: true, center: sample.center, vertices: vertices, edges: sample.edges)
        let layout = GraphLayout(neighborhood: stray, size: size)
        XCTAssertEqual(layout.rings[9], 3)
        XCTAssertEqual(layout.depth, 3)
        XCTAssertNotNil(layout.positions[9])
    }

    func testALoneCenterHasNoRings() {
        let lone = GraphNeighborhood(available: true, center: vertex(1), vertices: [vertex(1)])
        let layout = GraphLayout(neighborhood: lone, size: size)
        XCTAssertEqual(layout.depth, 0)
        XCTAssertEqual(layout.positions, [1: layout.origin])
        XCTAssertTrue(GraphLayout(neighborhood: GraphNeighborhood(available: false), size: size).positions.isEmpty)
    }

    func testTheSameNeighborhoodAlwaysLaysOutTheSame() {
        XCTAssertEqual(GraphLayout(neighborhood: sample, size: size), GraphLayout(neighborhood: sample, size: size))
    }

    func testHitTestingFindsTheNearestVertexWithinItsCircle() {
        let layout = GraphLayout(neighborhood: sample, size: size)
        let ada = layout.positions[4]!
        XCTAssertEqual(layout.vertex(at: CGPoint(x: ada.x + 3, y: ada.y - 2), radius: 8), 4)
        XCTAssertEqual(layout.vertex(at: layout.origin, radius: 8), 1)
        XCTAssertNil(layout.vertex(at: CGPoint(x: 1, y: 1), radius: 8))
    }

    func testCollidingVerticesArePushedApartAroundWhereTheyWanted() {
        XCTAssertEqual(GraphLayout.spreadApart([1.0]), [1.0])
        // Two vertices wanting the same angle end up either side of it, a separation apart.
        let pair = GraphLayout.spreadApart([1.0, 1.0])
        XCTAssertEqual(pair[1] - pair[0], .pi / 6, accuracy: 0.001)
        XCTAssertEqual((pair[0] + pair[1]) / 2, 1.0, accuracy: 0.001)
        // Vertices already far enough apart stay put.
        XCTAssertEqual(GraphLayout.spreadApart([0, 1, 2]), [0, 1, 2])
        // A ring too crowded to honour anyone's wish is spaced evenly instead.
        let crowded = GraphLayout.spreadApart(Array(repeating: 0, count: 12) + Array(repeating: 3, count: 12))
        XCTAssertEqual(crowded, GraphLayout.evenlySpaced(count: 24, from: 0))
    }

    func testTheMeanAngleWrapsAroundTheCircle() {
        // 170° and -170° average to 180°, not to 0°.
        XCTAssertEqual(abs(GraphLayout.meanAngle([170 * .pi / 180, -170 * .pi / 180])), .pi, accuracy: 0.001)
        XCTAssertEqual(GraphLayout.meanAngle([0, .pi / 2]), .pi / 4, accuracy: 0.001)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func angle(_ point: CGPoint, from origin: CGPoint) -> CGFloat {
        atan2(point.y - origin.y, point.x - origin.x)
    }
}
