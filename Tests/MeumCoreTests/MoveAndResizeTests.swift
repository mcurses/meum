import CoreGraphics
import XCTest
@testable import MeumCore

final class MoveTabTests: XCTestCase {
    /// Two cards side by side: a = [t1, t2], b = [t3].
    func twoCards() -> (Workspace, a: UUID, b: UUID, t1: UUID, t2: UUID, t3: UUID) {
        var ws = Workspace.make(name: "w")
        let a = ws.cards[0].id
        let t1 = ws.allTabs[0].id
        let t2 = Tab()
        ws.addTab(t2, toCard: a)
        let t3 = Tab()
        let b = ws.split(a, placement: .right, tab: t3)!
        return (ws, a, b, t1, t2.id, t3.id)
    }

    func tabIDs(_ ws: Workspace, _ card: UUID) -> [UUID] { ws.card(card)!.tabs.map(\.id) }

    func testMoveIntoOtherCardAtIndex() {
        var (ws, a, b, t1, t2, t3) = twoCards()
        XCTAssertTrue(ws.moveTab(t2, toCard: b, index: 0))
        XCTAssertEqual(tabIDs(ws, a), [t1])
        XCTAssertEqual(tabIDs(ws, b), [t2, t3])
        XCTAssertEqual(ws.card(b)!.selectedTabID, t2)
        XCTAssertEqual(ws.focusedCardID, b)
    }

    func testMoveIndexDefaultsToEndAndClamps() {
        var (ws, _, b, t1, _, t3) = twoCards()
        ws.moveTab(t1, toCard: b, index: 99)
        XCTAssertEqual(tabIDs(ws, b), [t3, t1])
    }

    func testMovingLastTabRemovesCardAndCollapses() {
        var (ws, a, b, t1, t2, t3) = twoCards()
        XCTAssertTrue(ws.moveTab(t3, toCard: a, index: 1))
        XCTAssertNil(ws.card(b))
        guard case .card(let only) = ws.root else { return XCTFail("split did not collapse") }
        XCTAssertEqual(only.id, a)
        XCTAssertEqual(only.tabs.map(\.id), [t1, t3, t2])
        XCTAssertEqual(only.selectedTabID, t3)
        XCTAssertEqual(ws.focusedCardID, a)
    }

    func testReorderWithinCard() {
        var (ws, a, _, t1, t2, _) = twoCards()
        XCTAssertTrue(ws.moveTab(t1, toCard: a, index: 1))
        XCTAssertEqual(tabIDs(ws, a), [t2, t1])
        XCTAssertTrue(ws.moveTab(t1, toCard: a, index: 0))
        XCTAssertEqual(tabIDs(ws, a), [t1, t2])
        XCTAssertEqual(ws.card(a)!.selectedTabID, t1)
    }

    func testOnlyTabWithinItsCardIsNoop() {
        var (ws, _, b, _, _, t3) = twoCards()
        let before = ws.root
        XCTAssertTrue(ws.moveTab(t3, toCard: b, index: 0))
        XCTAssertEqual(ws.root, before)
        XCTAssertEqual(ws.focusedCardID, b)
    }

    func testMoveUnknown() {
        var (ws, a, _, t1, _, _) = twoCards()
        XCTAssertFalse(ws.moveTab(UUID(), toCard: a))
        XCTAssertFalse(ws.moveTab(t1, toCard: UUID()))
    }

    func testSplitSides() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
        for side in Direction.allCases {
            var (ws, a, b, _, t2, _) = twoCards()
            guard let n = ws.moveTab(t2, splitting: b, side: side) else { return XCTFail("\(side)") }
            XCTAssertEqual(tabIDs(ws, n), [t2])
            XCTAssertEqual(ws.focusedCardID, n)
            XCTAssertEqual(ws.cards.count, 3)
            XCTAssertEqual(ws.card(a)!.tabs.count, 1)
            let f = ws.frames(in: rect, gap: 10)
            let nf = f[n]!, bf = f[b]!
            switch side {
            case .left: XCTAssertLessThan(nf.maxX, bf.minX); XCTAssertEqual(nf.minY, bf.minY)
            case .right: XCTAssertGreaterThan(nf.minX, bf.maxX); XCTAssertEqual(nf.minY, bf.minY)
            case .up: XCTAssertLessThan(nf.maxY, bf.minY); XCTAssertEqual(nf.minX, bf.minX)
            case .down: XCTAssertGreaterThan(nf.minY, bf.maxY); XCTAssertEqual(nf.minX, bf.minX)
            }
            XCTAssertEqual(nf.width * nf.height, bf.width * bf.height, accuracy: nf.height + nf.width)
        }
    }

    func testSplitWithLastTabOfOtherCardCollapsesSource() {
        var (ws, a, b, _, _, t3) = twoCards()
        let n = ws.moveTab(t3, splitting: a, side: .down)!
        XCTAssertNil(ws.card(b))
        guard case .split(let s) = ws.root else { return XCTFail() }
        XCTAssertEqual(s.axis, .vertical)
        XCTAssertEqual(s.first.cards.map(\.id), [a])
        XCTAssertEqual(s.second.cards.map(\.id), [n])
    }

    func testSplitOwnCardWithItsOnlyTabIsNoop() {
        var (ws, _, b, _, _, t3) = twoCards()
        let before = ws
        XCTAssertNil(ws.moveTab(t3, splitting: b, side: .left))
        XCTAssertEqual(ws, before)
    }

    func testSplitOwnCardWithOneOfSeveralTabs() {
        var (ws, a, _, t1, t2, _) = twoCards()
        let n = ws.moveTab(t1, splitting: a, side: .up)!
        XCTAssertEqual(tabIDs(ws, a), [t2])
        XCTAssertEqual(tabIDs(ws, n), [t1])
        XCTAssertEqual(ws.cards.count, 3)
    }

    func testMoveAcrossWorkspaces() {
        var s = AppState()
        let w1 = Workspace.make(name: "1")
        var w2 = Workspace.make(name: "2")
        let t = Tab()
        w2.addTab(t)
        s.addWorkspace(w1)
        s.addWorkspace(w2)
        let target = w1.cards[0].id
        XCTAssertTrue(s.moveTab(t.id, toCard: target, index: 0))
        XCTAssertEqual(s.workspace(w1.id)!.cards[0].tabs.first?.id, t.id)
        XCTAssertEqual(s.workspace(w2.id)!.allTabs.count, 1)
        // moving the other workspace's last tab leaves it empty
        let last = s.workspace(w2.id)!.allTabs[0].id
        XCTAssertNotNil(s.moveTab(last, splitting: target, side: .right))
        XCTAssertNil(s.workspace(w2.id)!.root)
        XCTAssertEqual(s.workspace(w1.id)!.cards.count, 2)
    }

    func testAppStateSetRatio() {
        var s = AppState()
        var w = Workspace.make(name: "1")
        w.split(placement: .right, tab: Tab())
        s.addWorkspace(w)
        guard case .split(let sp) = s.workspaces[0].root else { return XCTFail() }
        XCTAssertTrue(s.setRatio(split: sp.id, ratio: 0.3))
        XCTAssertEqual(s.workspaces[0].split(sp.id)?.ratio, 0.3)
        XCTAssertTrue(s.setRatio(split: sp.id, ratio: 5))
        XCTAssertEqual(s.workspaces[0].split(sp.id)?.ratio, 0.9)
        XCTAssertFalse(s.setRatio(split: UUID(), ratio: 0.5))
    }
}

final class DividerTests: XCTestCase {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testDividersMatchGaps() {
        var ws = Workspace.make(name: "a")
        let a = ws.cards[0].id
        let b = ws.split(placement: .right, tab: Tab())!
        let c = ws.split(b, placement: .down, tab: Tab())!
        let f = ws.frames(in: rect, gap: 10)
        let d = ws.dividers(in: rect, gap: 10)
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d[0].axis, .horizontal)
        XCTAssertEqual(d[0].rect, CGRect(x: f[a]!.maxX, y: 0, width: 10, height: 600))
        XCTAssertEqual(d[0].span, rect)
        XCTAssertEqual(d[1].axis, .vertical)
        XCTAssertEqual(d[1].rect, CGRect(x: f[b]!.minX, y: f[b]!.maxY, width: f[b]!.width, height: 10))
        XCTAssertEqual(d[1].rect.maxY, f[c]!.minY)
        XCTAssertTrue(Workspace.make(name: "x").dividers(in: rect, gap: 10).isEmpty)
    }

    func testRatioFollowsPosition() {
        var ws = Workspace.make(name: "a")
        ws.split(placement: .right, tab: Tab())
        let s = ws.root!.splits[0].id
        // divider centre at x = 305: first child 300 wide out of 990
        let r = ws.ratio(forSplit: s, dividerAt: 305, in: rect, gap: 10, minCard: 100)!
        XCTAssertEqual(r, 300.0 / 990.0, accuracy: 1e-9)
        ws.setRatio(split: s, ratio: r)
        let a = ws.cards[0].id
        XCTAssertEqual(ws.frames(in: rect, gap: 10)[a]!.width, 300)
    }

    func testRatioRespectsMinSizes() {
        var ws = Workspace.make(name: "a")
        let b = ws.split(placement: .right, tab: Tab())!
        ws.split(b, placement: .right, tab: Tab())  // right side holds two cards side by side
        let outer = ws.root!.splits[0].id
        let lo = ws.ratio(forSplit: outer, dividerAt: -50, in: rect, gap: 10, minCard: 150)!
        XCTAssertEqual(lo, 150.0 / 990.0, accuracy: 1e-9)
        // the second child needs 150 + 10 + 150
        let hi = ws.ratio(forSplit: outer, dividerAt: 5000, in: rect, gap: 10, minCard: 150)!
        XCTAssertEqual(hi, (990.0 - 310.0) / 990.0, accuracy: 1e-9)
        XCTAssertNil(ws.ratio(forSplit: UUID(), dividerAt: 10, in: rect, gap: 10, minCard: 150))
    }

    func testMinExtentAcrossAxes() {
        var ws = Workspace.make(name: "a")
        let b = ws.split(placement: .right, tab: Tab())!
        ws.split(b, placement: .down, tab: Tab())
        XCTAssertEqual(ws.root!.minExtent(.horizontal, minCard: 100, gap: 10), 210)
        XCTAssertEqual(ws.root!.minExtent(.vertical, minCard: 100, gap: 10), 210)
        ws.split(b, placement: .right, tab: Tab())
        XCTAssertEqual(ws.root!.minExtent(.horizontal, minCard: 100, gap: 10), 320)
    }
}
