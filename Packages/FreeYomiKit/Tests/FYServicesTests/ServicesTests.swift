import XCTest
@testable import FYServices
import FYData
import FYSources
import FYDomain
import FYCore

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

final class LocalImportServiceTests: XCTestCase {
    func testImportAddsToLibraryAndDeleteCleansEverything() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let localStore = LocalLibraryStore(root: tmp.appendingPathComponent("LocalFiles"))
        let db = try DataStore.inMemory()
        let service = LibraryService(store: db, registry: .makeDefault(localStore: localStore))

        var w = ZipWriter()
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); png.append(Data(count: 20))
        try w.add(path: "01.png", data: png)
        try w.add(path: "02.png", data: png)
        let good = tmp.appendingPathComponent("bom.cbz")
        try w.finish().write(to: good)
        let bad = tmp.appendingPathComponent("ruim.cbz")
        try Data("lixo".utf8).write(to: bad)

        let report = await service.importLocal(urls: [good, bad, good], importer: LocalImporter(store: localStore))
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(report.duplicates.count, 1)
        XCTAssertEqual(report.failures.map(\.name), ["ruim.cbz"])

        let items = try db.library.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].manga.sourceId, .local)
        XCTAssertEqual(items[0].totalChapters, 1)
        XCTAssertFalse(items[0].manga.isDemo)

        try service.deleteLocalManga(items[0].manga, store: localStore)
        XCTAssertTrue(try db.library.items().isEmpty)
        XCTAssertTrue(localStore.all().isEmpty)
    }
}
