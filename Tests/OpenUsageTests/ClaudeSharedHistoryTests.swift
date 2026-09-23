import XCTest
@testable import OpenUsage

/// Claude's local history when several accounts are signed in. Claude Code writes no account id into
/// a session log, so per-account attribution discards nearly everything; the group shares one
/// combined history instead, the same way Codex does.
final class ClaudeSharedHistoryTests: XCTestCase {
    private typealias Entry = ClaudeLogUsageScanner.Entry

    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "claude-test-model": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 12.5, cacheReadPerMillion: 1,
                fastMultiplier: 2
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    // MARK: - The sessions that used to be thrown away

    func testSharedScanCountsSessionsNoAccountClaims() async throws {
        // A log with no ownership header is what Claude Code actually writes. With several accounts
        // signed in this used to be dropped, which zeroed the spend tiles for every card.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a",
            allowsUnattributedSessions: false, sharesLocalHistory: true
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 150)
    }

    func testPerAccountScanStillDropsThem() async throws {
        // The unshared path is unchanged: one account's card never claims another's usage.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: "org-a",
            allowsUnattributedSessions: false, sharesLocalHistory: false
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(scan?.series.daily.first?.totalTokens ?? 0, 0)
    }

    func testSharedScanKeepsWorkingForADefaultLoginWithNoOrganization() async throws {
        // This combination used to bail out before reading a single file.
        let now = Date()
        let home = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "workspace/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: OpenUsageISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25
            )
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let scan = await ClaudeLogUsageScanner(
            environment: FakeEnvironment([:]), homeDirectory: { home },
            incrementalScanner: IncrementalJSONLScanner<Entry>(),
            accountUUID: "user-a", organizationUUID: nil,
            allowsUnattributedSessions: false, sharesLocalHistory: true
        ).scan(now: now, pricing: pricing)

        XCTAssertEqual(try XCTUnwrap(scan).series.daily.first?.totalTokens, 150)
    }

    // MARK: - What the provider declares

    @MainActor
    func testSharedProviderMarksOnlyItsHistoryRows() throws {
        let descriptors = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude@a"), sharesLocalHistory: true
        ).widgetDescriptors

        let trend = try XCTUnwrap(descriptors.first { $0.sample.isChart })
        XCTAssertEqual(trend.historyResource?.sharedGroup, "claude")
        XCTAssertTrue(descriptors.filter { $0.isSpendTile }.allSatisfy(\.sample.isSharedHistory))
        // A quota row is this account's own and is never badged shared.
        XCTAssertTrue(descriptors.filter { !$0.isSpendTile && !$0.sample.isChart }
            .allSatisfy { !$0.sample.isSharedHistory })
    }

    @MainActor
    func testUnsharedProviderDeclaresNoGroup() throws {
        let descriptors = ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: "claude"), sharesLocalHistory: false
        ).widgetDescriptors

        let trend = try XCTUnwrap(descriptors.first { $0.sample.isChart })
        XCTAssertNil(trend.historyResource?.sharedGroup)
        XCTAssertTrue(descriptors.allSatisfy { !$0.sample.isSharedHistory })
    }

    @MainActor
    func testSharedHistoryIsNeverServedFromTheAccountCache() {
        // Shared history belongs to the group, so a card must not restore it as its own.
        XCTAssertFalse(ClaudeProvider(sharesLocalHistory: true).allowsCachedLocalHistory)
        XCTAssertTrue(ClaudeProvider(sharesLocalHistory: false).allowsCachedLocalHistory)
    }

    // MARK: - When the app turns it on

    @MainActor
    func testSeveralAccountsShareHistoryAndASingleAccountDoesNot() throws {
        let many = ProviderCatalog.make(defaults: defaults(), claudeCards: [
            card(id: "claude@a", organization: "org-a"),
            card(id: "claude@b", organization: "org-b")
        ]).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(many.count, 2)
        XCTAssertTrue(many.allSatisfy(\.sharesLocalHistory))

        let one = ProviderCatalog.make(defaults: defaults(), claudeCards: [
            card(id: "claude@a", organization: "org-a")
        ]).compactMap { $0 as? ClaudeProvider }
        XCTAssertEqual(one.count, 1)
        XCTAssertFalse(one[0].sharesLocalHistory)
    }

    // MARK: - Helpers

    @MainActor
    private func defaults() -> UserDefaults {
        let name = "ClaudeSharedHistory.\(UUID().uuidString)"
        let result = UserDefaults(suiteName: name)!
        addTeardownBlock { result.removePersistentDomain(forName: name) }
        return result
    }

    private func card(id: String, organization: String) -> ClaudeAccountCard {
        ClaudeAccountCard(
            id: id, identityKey: "user-\(id)|\(organization)", organizationID: organization,
            displayName: "Claude: \(id)", usesDesktopCredentials: false,
            allowsUnattributedPiUsage: false
        )
    }
}
