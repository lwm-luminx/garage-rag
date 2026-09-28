import XCTest
@testable import GarageApp

final class DatabasePresentationTests: XCTestCase {

    // MARK: - Headline

    func testRunningHeadlineCarriesPortDocumentsAndSize() {
        let headline = DatabaseHeadline(
            status: .running, port: 14824, pendingMigrations: 0, isResetting: false,
            documents: 1234, sizeBytes: 5_000_000
        )
        XCTAssertEqual(headline.title, "Running")
        XCTAssertEqual(headline.tint, .green)
        XCTAssertTrue(headline.detail.hasPrefix("On this Mac, port 14824 · 1,234 documents · "), headline.detail)
        XCTAssertFalse(headline.detailIsError)
    }

    func testRunningHeadlineLeavesOutWhatIsNotKnownYet() {
        let headline = DatabaseHeadline(
            status: .running, port: 14824, pendingMigrations: 0, isResetting: false, documents: nil, sizeBytes: nil
        )
        XCTAssertEqual(headline.detail, "On this Mac, port 14824")
    }

    func testPendingMigrationsTurnTheHeadlineOrange() {
        let headline = DatabaseHeadline(
            status: .running, port: 14824, pendingMigrations: 2, isResetting: false, documents: 10, sizeBytes: nil
        )
        XCTAssertEqual(headline.title, "Needs a schema update")
        XCTAssertEqual(headline.tint, .orange)
        XCTAssertTrue(headline.detail.hasPrefix("2 schema updates"), headline.detail)

        let one = DatabaseHeadline(
            status: .needsMigration, port: 14824, pendingMigrations: 1, isResetting: false, documents: nil, sizeBytes: nil
        )
        XCTAssertTrue(one.detail.hasPrefix("1 schema update to apply"), one.detail)
    }

    func testFailedHeadlineShowsTheErrorInRed() {
        let headline = DatabaseHeadline(
            status: .failed("port 14824 is in use"), port: 14824, pendingMigrations: 0, isResetting: false,
            documents: nil, sizeBytes: nil
        )
        XCTAssertEqual(headline.title, "Couldn't start")
        XCTAssertEqual(headline.detail, "port 14824 is in use")
        XCTAssertTrue(headline.detailIsError)
    }

    func testStoppedHeadlineIsInactive() {
        let headline = DatabaseHeadline(
            status: .stopped, port: 14824, pendingMigrations: 0, isResetting: false, documents: nil, sizeBytes: nil
        )
        XCTAssertEqual(headline.title, "Stopped")
        XCTAssertFalse(headline.isActive)
    }

    func testResettingWinsOverEveryStatus() {
        let headline = DatabaseHeadline(
            status: .running, port: 14824, pendingMigrations: 3, isResetting: true, documents: 1, sizeBytes: 1
        )
        XCTAssertEqual(headline.title, "Resetting…")
    }

    // MARK: - Schema

    func testSchemaUpToDateOffersCheckAgain() {
        let schema = DatabaseSchemaPresentation(status: .running, pendingMigrations: [], isApplying: false)
        XCTAssertEqual(schema.title, "Schema up to date")
        XCTAssertEqual(schema.action, .check)
    }

    func testPendingMigrationsOfferApply() {
        let schema = DatabaseSchemaPresentation(
            status: .needsMigration, pendingMigrations: ["013_fact_prompts.sql", "014_x.sql"], isApplying: false
        )
        XCTAssertEqual(schema.title, "2 updates to apply")
        XCTAssertEqual(schema.action, .apply)

        let unknownCount = DatabaseSchemaPresentation(status: .needsMigration, pendingMigrations: [], isApplying: false)
        XCTAssertEqual(unknownCount.action, .apply)
    }

    func testSchemaWhileApplyingOrStoppedHasNoButton() {
        XCTAssertEqual(
            DatabaseSchemaPresentation(status: .running, pendingMigrations: ["a.sql"], isApplying: true).action,
            .hidden
        )
        let stopped = DatabaseSchemaPresentation(status: .stopped, pendingMigrations: [], isApplying: false)
        XCTAssertEqual(stopped.action, .hidden)
        XCTAssertFalse(stopped.isActive)
    }

    // MARK: - Contents

    func testContentsFigures() {
        let stats = CorpusStats(
            sourcesCount: 3,
            documentsCount: 1200,
            documentsFailedCount: 4,
            totalChunks: 1000,
            embeddedChunks: 500,
            modelStats: [
                .init(slug: "bge-m3", tableName: "emb_bge_m3", isDefault: true, embeddedCount: 1000),
                .init(slug: "nomic", tableName: "emb_nomic", isDefault: false, embeddedCount: 500),
            ]
        )
        let contents = DatabaseContentsPresentation(stats: stats, sizeBytes: nil)
        XCTAssertEqual(contents.figures.map(\.label), ["Sources", "Documents", "Chunks", "Indexed"])
        XCTAssertEqual(contents.figures[1].value, "1,200")
        XCTAssertEqual(contents.figures[1].note, "4 failed")
        XCTAssertTrue(contents.figures[1].noteIsWarning)
        XCTAssertEqual(contents.figures[3].value, "75%")
        XCTAssertEqual(contents.figures[3].note, "2 models")
        XCTAssertFalse(contents.isEmpty)
    }

    func testContentsWithoutModelsOrSize() {
        let contents = DatabaseContentsPresentation(stats: CorpusStats(), sizeBytes: 2048)
        XCTAssertEqual(contents.figures.map(\.label), ["Sources", "Documents", "Chunks", "Indexed", "On Disk"])
        XCTAssertEqual(contents.figures[3].value, "—")
        XCTAssertEqual(contents.figures[3].note, "No models")
        XCTAssertNil(contents.figures[1].note)
        XCTAssertTrue(contents.isEmpty)
    }

    // MARK: - Server details

    func testServerDetailsFromRows() {
        let details = DatabaseServerDetails(rows: [
            ["server", "18.0", "123456"],
            ["extension", "vector", "0.8.1"],
            ["extension", "age", "1.6.0"],
        ])
        XCTAssertEqual(details.serverVersion, "18.0")
        XCTAssertEqual(details.databaseSizeBytes, 123_456)
        XCTAssertEqual(details.extensions.map(\.name), ["age", "vector"])
        XCTAssertEqual(details.extensions.last?.version, "0.8.1")
    }

    // MARK: - Last backup

    func testBackupRecordRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DatabasePresentationTests"))
        defaults.removePersistentDomain(forName: "DatabasePresentationTests")
        XCTAssertNil(DatabaseBackupRecord(
            timestamp: defaults.double(forKey: DatabaseBackupRecord.dateKey),
            path: defaults.string(forKey: DatabaseBackupRecord.pathKey) ?? ""
        ))

        let url = URL(fileURLWithPath: "/tmp/garage-rag-20260925.dump")
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        DatabaseBackupRecord.record(url, at: date, defaults: defaults)
        let record = try XCTUnwrap(DatabaseBackupRecord(
            timestamp: defaults.double(forKey: DatabaseBackupRecord.dateKey),
            path: defaults.string(forKey: DatabaseBackupRecord.pathKey) ?? ""
        ))
        XCTAssertEqual(record.url, url)
        XCTAssertEqual(record.date, date)
        defaults.removePersistentDomain(forName: "DatabasePresentationTests")
    }
}
