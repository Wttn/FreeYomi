import XCTest
@testable import FYServices
import FYData
import FYSources
import FYDomain

final class LibraryServiceTests: XCTestCase {
    func testDemoSeedRunsOnceAndIsRemovable() async throws {
        let store = try DataStore.inMemory()
        let service = LibraryService(store: store, registry: .makeDefault())
        try await service.seedDemoDataIfNeeded()
        let items = try store.library.items()
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items.allSatisfy { $0.manga.isDemo })
        XCTAssertEqual(try store.history.recent().count, 3)

        try await service.seedDemoDataIfNeeded()
        XCTAssertEqual(try store.library.items().count, 4, "não duplica na segunda execução")

        try store.library.deleteDemoData()
        XCTAssertTrue(try store.library.items().isEmpty)
        XCTAssertTrue(try store.history.recent().isEmpty, "histórico demo removido em cascata")
    }

    func testRefreshFindsNoNewChaptersForStableSource() async throws {
        let store = try DataStore.inMemory()
        let service = LibraryService(store: store, registry: .makeDefault())
        try await service.seedDemoDataIfNeeded()
        let report = await service.refreshLibrary(skipCompleted: true)
        XCTAssertEqual(report.skipped, 1, "um título demo está concluído")
        XCTAssertEqual(report.updated, 3)
        XCTAssertTrue(report.newChapters.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testMissingSourceIsReportedNotCrashing() async throws {
        let store = try DataStore.inMemory()
        let id = try store.library.upsertManga(Manga(sourceId: "nao-instalada", key: "x", title: "Órfão"))
        try store.library.add(mangaId: id)
        let service = LibraryService(store: store, registry: .makeDefault())
        let report = await service.refreshLibrary(skipCompleted: false)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(report.failures[0].1.contains("não está instalada"))
    }
}
