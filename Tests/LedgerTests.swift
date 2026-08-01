import XCTest
@testable import Fridge

// TIER 1 test — pure logic, no OS calls beyond ordinary file I/O against
// Ledger.storeURL. Written blind on Windows, never compiled. First thing to
// run tomorrow once the app target + a unit test target exist in Xcode.
//
// Module name assumption: `@testable import Fridge`. Info.plist's
// CFBundleName is "Fridge" and there is no .xcodeproj yet (see
// UNCERTAINTIES.md #14) — if the app target created tomorrow ends up named
// something else, change the import line to match.
//
// Ledger.storeURL is a fixed real path
// (~/Library/Application Support/Fridge/ledger.json), not injectable —
// Ledger has no constructor hook for a test directory, and CLAUDE.md says
// not to modify production code to make it "more testable". So these tests
// back up whatever is really at that path before each test and restore it
// afterward, to guarantee a clean slate without ever losing real data.
final class LedgerTests: XCTestCase {

    private var backupData: Data?

    private var ledgerURL: URL {
        Ledger.storeURL
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            backupData = try Data(contentsOf: ledgerURL)
            try FileManager.default.removeItem(at: ledgerURL)
        } else {
            backupData = nil
        }
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            try FileManager.default.removeItem(at: ledgerURL)
        }
        if let backupData {
            try backupData.write(to: ledgerURL, options: .atomic)
            // Restoring the real ledger and reloading it sweeps any
            // icon files this test created that the real ledger (now
            // restored) doesn't reference — see Ledger.load()'s orphan
            // sweep.
            try Ledger().load()
        } else {
            // No real ledger existed before this test — nothing to
            // preserve, so just clear whatever icon files the test made.
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: Ledger.iconsDirectory, includingPropertiesForKeys: nil
            ) {
                for url in contents {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        try super.tearDownWithError()
    }

    // MARK: - Round trip

    /// Exercises the real JSONEncoder/JSONDecoder configuration used by
    /// save()/load(): .iso8601 dates on both sides, and Data's default
    /// (base64) coding strategy since neither encoder nor decoder overrides
    /// dataEncodingStrategy/dataDecodingStrategy.
    ///
    /// ISO8601DateFormatter's default formatOptions (.withInternetDateTime,
    /// no fractional seconds) truncates sub-second precision on encode. So
    /// `lastUsed` below is constructed on a whole-second boundary and must
    /// come back byte-for-byte equal; `firstSeen` is stamped internally by
    /// register() as `Date()` (sub-second precision, out of the caller's
    /// control) and is checked with a < 1s tolerance for that documented
    /// reason, not because the round trip is actually lossy for anything
    /// else.
    func testRoundTripPreservesAllFields() throws {
        let path = "/Users/tester/Downloads/thing.pdf"
        let iconBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG magic bytes
        let lastUsed = Date(timeIntervalSince1970: 1_700_000_000) // whole seconds

        let writer = Ledger()
        try writer.load() // nonexistent at this point; establishes empty state like a real launch
        let beforeSave = writer.entry(for: path)
        XCTAssertNil(beforeSave)

        writer.register(path: path, cleanIconPNG: iconBytes, lastUsed: lastUsed)
        guard let registered = writer.entry(for: path) else {
            return XCTFail("expected entry immediately after register()")
        }
        writer.updateBucket(path: path, to: .moldy)
        try writer.save()

        let reader = Ledger()
        try reader.load()

        guard let loaded = reader.entry(for: path) else {
            return XCTFail("expected entry to survive a save/load round trip")
        }

        XCTAssertEqual(reader.cleanIconData(for: path), iconBytes)
        XCTAssertEqual(loaded.lastUsed, lastUsed)
        XCTAssertEqual(loaded.currentBucket, .moldy)
        XCTAssertEqual(loaded.frozen, false)
        XCTAssertLessThan(
            abs(loaded.firstSeen.timeIntervalSince1970 - registered.firstSeen.timeIntervalSince1970),
            1.0,
            "firstSeen should survive the round trip within iso8601's whole-second precision"
        )

        XCTAssertEqual(reader.allPaths, [path])
    }

    func testLoadOnNonexistentFileProducesEmptyLedgerWithoutThrowing() throws {
        // setUpWithError already guaranteed nothing real is at ledgerURL.
        let ledger = Ledger()
        XCTAssertNoThrow(try ledger.load())
        XCTAssertTrue(ledger.entries.isEmpty)
        XCTAssertTrue(ledger.allPaths.isEmpty)
    }

    // MARK: - register()

    func testRegisterIsNoOpIfPathAlreadyKnown() {
        let ledger = Ledger()
        let path = "/Users/tester/Desktop/first.png"
        let firstIcon = Data([0x01, 0x02, 0x03])
        let firstLastUsed = Date(timeIntervalSince1970: 1_000)

        ledger.register(path: path, cleanIconPNG: firstIcon, lastUsed: firstLastUsed)
        guard let original = ledger.entry(for: path) else {
            return XCTFail("expected entry after first register()")
        }

        // Second register() call for the same path, with different values —
        // should be completely ignored.
        let secondIcon = Data([0x09, 0x08, 0x07])
        let secondLastUsed = Date(timeIntervalSince1970: 2_000)
        ledger.register(path: path, cleanIconPNG: secondIcon, lastUsed: secondLastUsed)

        guard let unchanged = ledger.entry(for: path) else {
            return XCTFail("entry disappeared after a redundant register() call")
        }

        XCTAssertEqual(ledger.cleanIconData(for: path), firstIcon, "redundant register() must not overwrite the original clean icon")
        XCTAssertEqual(unchanged.lastUsed, original.lastUsed)
        XCTAssertEqual(unchanged.currentBucket, original.currentBucket)
        XCTAssertEqual(unchanged.frozen, original.frozen)
        XCTAssertEqual(unchanged.firstSeen, original.firstSeen)
        XCTAssertEqual(ledger.allPaths, [path], "redundant register() must not create a second entry")
    }

    func testRegisterOnNewPathDefaultsToFreshAndUnfrozen() {
        let ledger = Ledger()
        let path = "/Users/tester/Desktop/new.png"
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())

        guard let entry = ledger.entry(for: path) else {
            return XCTFail("expected entry after register()")
        }
        XCTAssertEqual(entry.currentBucket, .fresh)
        XCTAssertFalse(entry.frozen)
    }

    // MARK: - updateBucket()

    func testUpdateBucketAffectsOnlyExistingEntries() {
        let ledger = Ledger()
        let path = "/Users/tester/Downloads/known.txt"
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())

        ledger.updateBucket(path: "/Users/tester/Downloads/unknown.txt", to: .fuzzy)
        XCTAssertNil(ledger.entry(for: "/Users/tester/Downloads/unknown.txt"))
        XCTAssertEqual(ledger.allPaths, [path], "updateBucket on an unknown path must not create an entry")

        ledger.updateBucket(path: path, to: .fuzzy)
        XCTAssertEqual(ledger.entry(for: path)?.currentBucket, .fuzzy)
    }

    // MARK: - setFrozen()

    func testSetFrozenAffectsOnlyExistingEntries() {
        let ledger = Ledger()
        let path = "/Users/tester/Downloads/known.txt"
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())

        ledger.setFrozen(path: "/Users/tester/Downloads/unknown.txt", frozen: true)
        XCTAssertNil(ledger.entry(for: "/Users/tester/Downloads/unknown.txt"))
        XCTAssertEqual(ledger.allPaths, [path], "setFrozen on an unknown path must not create an entry")

        XCTAssertEqual(ledger.entry(for: path)?.frozen, false)
        ledger.setFrozen(path: path, frozen: true)
        XCTAssertEqual(ledger.entry(for: path)?.frozen, true)
        ledger.setFrozen(path: path, frozen: false)
        XCTAssertEqual(ledger.entry(for: path)?.frozen, false)
    }

    // MARK: - updateLastUsed()

    func testUpdateLastUsedAffectsOnlyExistingEntries() {
        let ledger = Ledger()
        let path = "/Users/tester/Downloads/known.txt"
        let originalDate = Date(timeIntervalSince1970: 1_000)
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: originalDate)

        let newDate = Date(timeIntervalSince1970: 2_000)
        ledger.updateLastUsed(path: "/Users/tester/Downloads/unknown.txt", to: newDate)
        XCTAssertNil(ledger.entry(for: "/Users/tester/Downloads/unknown.txt"))
        XCTAssertEqual(ledger.allPaths, [path], "updateLastUsed on an unknown path must not create an entry")

        ledger.updateLastUsed(path: path, to: newDate)
        XCTAssertEqual(ledger.entry(for: path)?.lastUsed, newDate)

        // updateLastUsed must not touch currentBucket (CLAUDE.md: the caller
        // decides whether to repaint).
        XCTAssertEqual(ledger.entry(for: path)?.currentBucket, .fresh)
    }

    // MARK: - forget()

    func testForgetRemovesEntry() {
        let ledger = Ledger()
        let path = "/Users/tester/Downloads/gone.txt"
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())
        XCTAssertNotNil(ledger.entry(for: path))

        ledger.forget(path: path)
        XCTAssertNil(ledger.entry(for: path))
        XCTAssertTrue(ledger.allPaths.isEmpty)
    }

    func testForgetOnUnknownPathIsSafeNoOp() {
        let ledger = Ledger()
        let path = "/Users/tester/Downloads/stays.txt"
        ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())

        ledger.forget(path: "/Users/tester/Downloads/never-registered.txt")

        XCTAssertEqual(ledger.allPaths, [path])
        XCTAssertNotNil(ledger.entry(for: path))
    }

    // MARK: - allPaths

    func testAllPathsReflectsExactlyWhatIsRegistered() {
        let ledger = Ledger()
        let paths = [
            "/Users/tester/Downloads/a.txt",
            "/Users/tester/Downloads/b.txt",
            "/Users/tester/Desktop/c.txt",
        ]
        for path in paths {
            ledger.register(path: path, cleanIconPNG: Data([0x01]), lastUsed: Date())
        }

        XCTAssertEqual(Set(ledger.allPaths), Set(paths))
        XCTAssertEqual(ledger.allPaths.count, paths.count)

        ledger.forget(path: paths[0])
        XCTAssertEqual(Set(ledger.allPaths), Set(paths.dropFirst()))
    }
}
