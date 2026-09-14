import XCTest
@testable import Cleanora

/// M-03 — the rules read ONLY item categories, sizes, appName groups and
/// paths (never reason strings), fire strictly above their thresholds, and
/// the result is capped at four, largest estimate first.
final class RecommendationEngineTests: TempHomeTestCase {
    private let megabyte: Int64 = 1_000_000
    private let gigabyte: Int64 = 1_000_000_000

    private func item(
        _ name: String,
        category: ScanCategory,
        size: Int64,
        appName: String? = nil,
        pathComponents: [String],
        risk: RiskLevel = .review,
        reason: String = "fixture reason"
    ) -> CleanupItem {
        CleanupItem(
            name: name,
            appName: appName,
            category: category,
            path: tempHome.appending(pathComponents),
            size: size,
            fileCount: 1,
            riskLevel: risk,
            reason: reason,
            deletionMethod: .trashDirectory
        )
    }

    private func result(_ items: [CleanupItem]) -> ScanResult {
        ScanResult(startedAt: Date(), finishedAt: Date(), items: items)
    }

    private var archivesComponents: [String] {
        ["Library", "Developer", "Xcode", "Archives", "MyApp 1.0.xcarchive"]
    }
    private var deviceSupportComponents: [String] {
        ["Library", "Developer", "Xcode", "iOS DeviceSupport", "16.4 (20F71)"]
    }
    private var homebrewComponents: [String] {
        ["Library", "Caches", "Homebrew"]
    }

    // MARK: - Empty + quiet results

    func testEmptyResultProducesNoRecommendations() {
        XCTAssertTrue(RecommendationEngine.recommendations(from: result([])).isEmpty)
    }

    func testQuietResultProducesNoRecommendations() {
        let quiet = result([
            item(
                "App cache", category: .applicationCaches, size: 400 * megabyte,
                pathComponents: ["Library", "Caches", "com.example.app"]
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: quiet).isEmpty)
    }

    // MARK: - Xcode archives

    func testArchivesAboveThresholdRecommended() {
        let scan = result([
            item(
                "Xcode — Archives", category: .developerData, size: 600 * megabyte,
                appName: "Xcode", pathComponents: archivesComponents
            ),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Old Xcode archives")
        XCTAssertEqual(recommendations[0].estimatedBytes, 600 * megabyte)
        XCTAssertEqual(recommendations[0].category, .developerData)
        XCTAssertFalse(recommendations[0].detail.isEmpty)
    }

    func testArchivesAtExactlyThresholdNotRecommended() {
        let scan = result([
            item(
                "Xcode — Archives", category: .developerData, size: 500 * megabyte,
                appName: "Xcode", pathComponents: archivesComponents
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    func testArchivesTotalledAcrossItemsBeforeThresholdCheck() {
        let scan = result([
            item("A.xcarchive", category: .developerData, size: 300 * megabyte,
                 appName: "Xcode", pathComponents: ["Library", "Developer", "Xcode", "Archives", "A.xcarchive"]),
            item("B.xcarchive", category: .developerData, size: 300 * megabyte,
                 appName: "Xcode", pathComponents: ["Library", "Developer", "Xcode", "Archives", "B.xcarchive"]),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].estimatedBytes, 600 * megabyte)
    }

    func testDerivedDataNeverCountsAsArchives() {
        let scan = result([
            item(
                "Xcode — DerivedData", category: .developerData, size: 600 * megabyte,
                appName: "Xcode",
                pathComponents: ["Library", "Developer", "Xcode", "DerivedData", "Project"]
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    // MARK: - iOS DeviceSupport

    func testDeviceSupportAboveThresholdRecommended() {
        let scan = result([
            item(
                "Xcode — iOS DeviceSupport", category: .developerData, size: 1500 * megabyte,
                appName: "Xcode", pathComponents: deviceSupportComponents
            ),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Old iOS device symbols")
        XCTAssertEqual(recommendations[0].estimatedBytes, 1500 * megabyte)
        XCTAssertEqual(recommendations[0].category, .developerData)
    }

    func testDeviceSupportBelowThresholdNotRecommended() {
        let scan = result([
            item(
                "Xcode — iOS DeviceSupport", category: .developerData, size: gigabyte,
                appName: "Xcode", pathComponents: deviceSupportComponents
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    // MARK: - Homebrew

    func testHomebrewCacheAboveThresholdRecommended() {
        let scan = result([
            item(
                "Homebrew cache", category: .developerData, size: 2500 * megabyte,
                appName: "Homebrew", pathComponents: homebrewComponents
            ),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Homebrew cache is large")
        XCTAssertEqual(recommendations[0].estimatedBytes, 2500 * megabyte)
        XCTAssertEqual(recommendations[0].category, .developerData)
    }

    func testHomebrewCacheBelowThresholdNotRecommended() {
        let scan = result([
            item(
                "Homebrew cache", category: .developerData, size: 2 * gigabyte,
                appName: "Homebrew", pathComponents: homebrewComponents
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    // MARK: - Docker (appName group only — never the reason string)

    func testDockerTotalledPerAppNameGroupAboveThreshold() {
        let scan = result([
            item("Docker build cache", category: .developerData, size: 6 * gigabyte,
                 appName: "Docker", pathComponents: ["Library", "Containers", "com.docker.docker", "Data"]),
            item("Docker VM disk", category: .developerData, size: Int64(4.5 * Double(gigabyte)),
                 appName: "Docker", pathComponents: ["Library", "Containers", "com.docker.docker", "Data"]),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Docker is using a lot of space")
        XCTAssertEqual(recommendations[0].estimatedBytes, 10_500_000_000)
    }

    func testDockerBelowThresholdNotRecommended() {
        let scan = result([
            item("Docker build cache", category: .developerData, size: 9_500_000_000,
                 appName: "Docker", pathComponents: ["Library", "Containers", "com.docker.docker", "Data"]),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    /// I-rule: recommendations never read `reason` — a reason that happens to
    /// name Docker/archives cannot conjure a suggestion on its own.
    func testReasonTextNeverDrivesRules() {
        let scan = result([
            item(
                "App cache", category: .applicationCaches, size: 20 * gigabyte,
                pathComponents: ["Library", "Caches", "com.example.app"],
                reason: "Docker.raw is 20 GB; archives and device support and Homebrew and logs and Trash all live here."
            ),
        ])
        XCTAssertTrue(RecommendationEngine.recommendations(from: scan).isEmpty)
    }

    // MARK: - Trash + logs

    func testTrashAboveThresholdRecommended() {
        let scan = result([
            item("Trash", category: .trash, size: 6 * gigabyte,
                 pathComponents: [".Trash"], risk: .safe),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Trash is filling up")
        XCTAssertEqual(recommendations[0].estimatedBytes, 6 * gigabyte)
        XCTAssertEqual(recommendations[0].category, .trash)
    }

    func testLogsAboveThresholdRecommended() {
        let scan = result([
            item("Library/Logs", category: .logs, size: 1500 * megabyte,
                 pathComponents: ["Library", "Logs", "SomeApp"], risk: .safe),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 1)
        XCTAssertEqual(recommendations[0].title, "Old logs are piling up")
        XCTAssertEqual(recommendations[0].category, .logs)
    }

    // MARK: - Ordering + cap

    func testCappedAtFourSortedByEstimatedBytes() {
        let scan = result([
            item("Xcode — Archives", category: .developerData, size: 600 * megabyte,
                 appName: "Xcode", pathComponents: archivesComponents),
            item("Xcode — iOS DeviceSupport", category: .developerData, size: 1500 * megabyte,
                 appName: "Xcode", pathComponents: deviceSupportComponents),
            item("Homebrew cache", category: .developerData, size: 2500 * megabyte,
                 appName: "Homebrew", pathComponents: homebrewComponents),
            item("Docker build cache", category: .developerData, size: 11 * gigabyte,
                 appName: "Docker", pathComponents: ["Library", "Containers", "com.docker.docker", "Data"]),
            item("Trash", category: .trash, size: 6 * gigabyte,
                 pathComponents: [".Trash"], risk: .safe),
            item("Library/Logs", category: .logs, size: 1500 * megabyte,
                 pathComponents: ["Library", "Logs", "SomeApp"], risk: .safe),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.count, 4, "at most four suggestions")
        XCTAssertEqual(recommendations.map(\.estimatedBytes), [
            11 * gigabyte, 6 * gigabyte, 2500 * megabyte, 1500 * megabyte,
        ], "largest estimate first")
        XCTAssertEqual(recommendations.map(\.title), [
            "Docker is using a lot of space",
            "Trash is filling up",
            "Homebrew cache is large",
            "Old iOS device symbols", // ties with the logs rule on size; title breaks it
        ])
    }

    func testEqualEstimatesBreakTiesByTitle() {
        let scan = result([
            item("Trash", category: .trash, size: 6 * gigabyte,
                 pathComponents: [".Trash"], risk: .safe),
            item("Library/Logs", category: .logs, size: 6 * gigabyte,
                 pathComponents: ["Library", "Logs", "SomeApp"], risk: .safe),
        ])
        let recommendations = RecommendationEngine.recommendations(from: scan)

        XCTAssertEqual(recommendations.map(\.title), [
            "Old logs are piling up", "Trash is filling up",
        ])
    }
}
