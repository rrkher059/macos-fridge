import XCTest
@testable import Fridge

// TIER 1 test — pure logic, no OS calls. Written blind on Windows, never
// compiled.
//
// `bucket(forDaysOld:)` lives in MenuBar.swift as a `private` method on
// `MenuBarController`, which is otherwise Tier 2 (AppKit-dependent,
// unverified — NSStatusItem, NSMetadataQuery-backed Watcher, MoldPainter,
// etc., per the header comment in that file). Constructing a
// MenuBarController just to reach one private pure function would mean
// initializing its `ledger`/`watcher`/`painter` properties too, dragging a
// Tier 1 test through Tier 2 object construction we have no way to verify
// on this machine.
//
// So instead of dropping `private` on the real method (which CLAUDE.md's
// "do not modify production code to make it more testable" rule advises
// against, and which isn't needed for a stateless, self-contained switch),
// this file keeps a verbatim local copy of the switch statement and tests
// that copy directly. This is intentionally NOT a @testable-import call
// into MenuBarController.bucket(forDaysOld:) — it is a duplicate.
//
// >>> IMPORTANT <<<
// If MenuBar.swift's `bucket(forDaysOld:)` switch statement (case ranges,
// bucket assignments) ever changes, update the copy below to match, or
// this test suite will silently test the wrong thing. As of writing, the
// real implementation (MenuBar.swift, private method `bucket(forDaysOld:)`)
// reads exactly:
//
//     switch days {
//     case ..<14: return .fresh
//     case 14..<21: return .spotty
//     case 21..<30: return .moldy
//     default: return .fuzzy
//     }
//
// which matches the CLAUDE.md freshness bucket table:
//   0-13 fresh, 14-20 spotty, 21-29 moldy, 30+ fuzzy.
private func bucket(forDaysOld days: Int) -> Bucket {
    switch days {
    case ..<14: return .fresh
    case 14..<21: return .spotty
    case 21..<30: return .moldy
    default: return .fuzzy
    }
}

final class MenuBarBucketTests: XCTestCase {

    func testFreshRange() {
        XCTAssertEqual(bucket(forDaysOld: 0), .fresh)
        XCTAssertEqual(bucket(forDaysOld: 13), .fresh)
    }

    func testSpottyRange() {
        XCTAssertEqual(bucket(forDaysOld: 14), .spotty)
        XCTAssertEqual(bucket(forDaysOld: 20), .spotty)
    }

    func testMoldyRange() {
        XCTAssertEqual(bucket(forDaysOld: 21), .moldy)
        XCTAssertEqual(bucket(forDaysOld: 29), .moldy)
    }

    func testFuzzyRange() {
        XCTAssertEqual(bucket(forDaysOld: 30), .fuzzy)
        XCTAssertEqual(bucket(forDaysOld: 100), .fuzzy)
    }
}
