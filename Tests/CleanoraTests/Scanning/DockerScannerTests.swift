import XCTest
@testable import Cleanora

/// P-06 — DockerScanner. Frozen safety decision under test:
/// Docker.raw is measured READ-ONLY and its path is NEVER an item path;
/// the informational item points at the container's Data directory and is
/// meant to be gate-rejected by SafetyPolicy (deletion only via
/// `docker system prune`); discrete deletable items exist only for paths on
/// the scanner's validated cache allowlist.
final class DockerScannerTests: TempHomeTestCase {
    private let noProgress: @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }

    private var containerData: URL {
        environment.home.appending(["Library", "Containers", "com.docker.docker", "Data"])
    }
    private var rawDisk: URL {
        containerData.appendingPathComponent("vms/0/data/Docker.raw")
    }
    private var fixtureCache: URL {
        environment.home.appending(["Library", "Caches", "docker-build-cache"])
    }

    /// Writes the sparse-disk stand-in with block-aligned size so the
    /// allocated size is exact.
    private func makeRawDisk(bytes: Int = 4 * 1_048_576) throws {
        try FixtureBuilder.makeTree(in: rawDisk.deletingLastPathComponent(), [])
        try Data(repeating: 0x41, count: bytes).write(to: rawDisk, options: .atomic)
    }

    private func scan(
        cliInstalled: Bool = false,
        cachePathAllowlist: [URL] = [],
        onProgress: @escaping @Sendable (ScannerKey, ScannerState) -> Void = { _, _ in }
    ) async throws -> ScannerOutcome {
        let scanner = DockerScanner(
            cliDetector: { cliInstalled },
            cachePathAllowlist: cachePathAllowlist
        )
        return try await scanner.scan(
            in: environment,
            options: ScanOptions(includeDeveloperData: true),
            onProgress: onProgress
        )
    }

    private func producedItems(_ outcome: ScannerOutcome, file: StaticString = #filePath, line: UInt = #line)
        -> [CleanupItem] {
        guard case .produced(let items) = outcome else {
            XCTFail("expected .produced, got \(outcome)", file: file, line: line)
            return []
        }
        return items
    }

    // MARK: - Presence detection

    func testNeitherRawDiskNorCLIMeansToolNotInstalled() async throws {
        let outcome = try await scan(cliInstalled: false)
        XCTAssertEqual(outcome, .skipped(.toolNotInstalled("Docker")))
    }

    func testRawDiskAloneCountsAsInstalled() async throws {
        try makeRawDisk()
        let outcome = try await scan(cliInstalled: false)
        XCTAssertEqual(producedItems(outcome).count, 1)
    }

    func testCLIAloneProducesNoItems() async throws {
        // CLI present but nothing measurable on disk (e.g. engine on a
        // remote host): the row completes empty instead of lying about sizes.
        let outcome = try await scan(cliInstalled: true)
        XCTAssertEqual(producedItems(outcome), [])
    }

    // MARK: - The informational item (Docker.raw is never a target)

    func testRawDiskOnlyProducesOneReviewInformationalItem() async throws {
        try makeRawDisk(bytes: 4 * 1_048_576)

        let items = producedItems(try await scan())

        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.category, .developerData)
        XCTAssertEqual(item.appName, "Docker")
        XCTAssertEqual(item.riskLevel, .review)
        XCTAssertEqual(item.selected, false, "the Docker row is never preselected")
        XCTAssertEqual(item.deletionMethod, .moveToTrash)
        XCTAssertEqual(canonicalTestPath(item.path).path, canonicalTestPath(containerData).path)
        XCTAssertEqual(item.size, 4 * 1_048_576, "the item carries the measured Docker.raw size")

        XCTAssertTrue(item.reason.contains("Docker.raw"), "the reason names the real storage")
        XCTAssertTrue(
            item.reason.contains("docker system prune"),
            "the reason states exactly what the actual cleanup would run"
        )
        XCTAssertFalse(item.reason.isEmpty)
    }

    func testRawDiskPathIsNeverAnItemPath() async throws {
        try makeRawDisk()

        let items = producedItems(try await scan())

        for item in items {
            XCTAssertNotEqual(
                canonicalTestPath(item.path).path,
                canonicalTestPath(rawDisk).path,
                "deleting Docker.raw would destroy every image and container"
            )
            XCTAssertFalse(
                item.path.path.hasSuffix("Docker.raw"),
                "no item may point at the disk image itself"
            )
        }
    }

    func testInformationalItemIsRejectedByTheSafetyGate() throws {
        // The contract the whole Docker decision rests on: the marker item
        // must fail SafetyPolicy.validate, so the engine can never delete it
        // through the normal cleanup flow.
        try makeRawDisk()
        let policy = SafetyPolicy.standard(home: tempHome, tempRoot: tempRoot)
        let item = CleanupItem(
            name: "Docker build cache",
            appName: "Docker",
            category: .developerData,
            path: containerData,
            size: 4 * 1_048_576,
            riskLevel: .review,
            selected: true,
            reason: "informational",
            deletionMethod: .moveToTrash
        )

        XCTAssertThrowsError(try policy.validate(item, confirmed: [item.id])) { error in
            guard case SafetyPolicy.Violation.outsideAllowedRoots = error else {
                return XCTFail("expected .outsideAllowedRoots, got \(error)")
            }
        }
    }

    // MARK: - Discrete cache allowlist

    func testAllowlistedCachePathBecomesTheOnlyDeletableItem() async throws {
        try makeRawDisk()
        try FixtureBuilder.makeTree(in: fixtureCache, [("layers/abc123", 2_048)])

        let items = producedItems(
            try await scan(cachePathAllowlist: [fixtureCache])
        )

        XCTAssertEqual(items.count, 1, "discrete caches replace the informational item")
        let item = items[0]
        XCTAssertEqual(canonicalTestPath(item.path).path, canonicalTestPath(fixtureCache).path)
        XCTAssertEqual(item.riskLevel, .review)
        XCTAssertEqual(item.deletionMethod, .moveToTrash)
        XCTAssertGreaterThan(item.size, 0)
    }

    func testNonAllowlistedDockerPathsNeverBecomeItems() async throws {
        try makeRawDisk()
        let unlisted = environment.home.appending(["Library", "Containers", "com.docker.docker", "Data", "log"])
        try FixtureBuilder.makeTree(in: unlisted, [("vm.log", 1_024)])

        let items = producedItems(try await scan(cachePathAllowlist: [fixtureCache]))

        // The log dir is not on the allowlist, the raw disk is not deletable:
        // only the informational marker remains.
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(canonicalTestPath(items[0].path).path, canonicalTestPath(containerData).path)
    }
}
