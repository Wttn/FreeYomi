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

/// Fonte falsa para testar migração e busca global.
struct FakeSource: MangaSource {
    let id: SourceID
    let name: String
    let language = "pt-BR"
    let kind: SourceKind = .online
    let chapterNumbers: [Double]
    var failSearch = false

    func popular(page: Int) async throws -> MangaListPage { MangaListPage(items: [], hasNextPage: false) }
    func search(query: String, page: Int) async throws -> MangaListPage {
        if failSearch { throw FYError.network("fora do ar") }
        return MangaListPage(items: [SourceManga(key: "obra", title: "\(query) em \(name)")], hasNextPage: false)
    }
    func details(for manga: SourceManga) async throws -> SourceManga { SourceManga(key: manga.key, title: "Obra (\(name))") }
    func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        chapterNumbers.sorted(by: >).map { SourceChapter(key: "c\($0)", name: "Cap \($0)", number: $0) }
    }
    func pages(mangaKey: String, chapterKey: String) async throws -> [Page] { [] }
}

final class SourceMigrationTests: XCTestCase {
    func testMigrationCopiesReadStateCategoriesAndSwapsLibrary() async throws {
        let db = try DataStore.inMemory()
        let a = FakeSource(id: "fonte-a", name: "A", chapterNumbers: [1, 2, 3, 4])
        let b = FakeSource(id: "fonte-b", name: "B", chapterNumbers: [1, 2, 2.5, 3, 4, 5])
        let service = LibraryService(store: db, registry: SourceRegistry(sources: [a, b]))
        let cat = try db.categories.create(name: "Lendo")
        let old = try await service.addToLibrary(SourceManga(key: "obra", title: "Obra"), sourceId: "fonte-a", categoryIds: [cat.id])
        let oldChapters = try db.chapters.chapters(mangaId: old.id)
        try db.chapters.setRead(oldChapters.filter { $0.number <= 3 }.map(\.id), read: true)
        try db.chapters.setBookmarked(oldChapters.first { $0.number == 2 }!.id, true)

        let new = try await service.migrate(mangaId: old.id, to: SourceManga(key: "obra", title: "Obra"), sourceId: "fonte-b")

        let items = try db.library.items()
        XCTAssertEqual(items.map(\.manga.id), [new.id], "o original sai da biblioteca e o destino entra")
        XCTAssertEqual(items[0].entry.categoryIds, [cat.id])
        let newChapters = try db.chapters.chapters(mangaId: new.id)
        XCTAssertEqual(newChapters.filter(\.isRead).map(\.number), [1, 2, 2.5, 3], "lidos até o maior número lido")
        XCTAssertEqual(newChapters.filter(\.isBookmarked).map(\.number), [2])
        XCTAssertNotNil(try db.library.manga(id: old.id), "o título original (e seu histórico) é preservado")
    }

    func testMigrationToItselfIsRejected() async throws {
        let db = try DataStore.inMemory()
        let a = FakeSource(id: "fonte-a", name: "A", chapterNumbers: [1])
        let service = LibraryService(store: db, registry: SourceRegistry(sources: [a]))
        let m = try await service.addToLibrary(SourceManga(key: "obra", title: "Obra"), sourceId: "fonte-a")
        do {
            _ = try await service.migrate(mangaId: m.id, to: SourceManga(key: "obra", title: "Obra"), sourceId: "fonte-a")
            XCTFail("deveria recusar")
        } catch {}
    }

    func testGlobalSearchKeepsOrderAndIsolatesFailures() async throws {
        let db = try DataStore.inMemory()
        let a = FakeSource(id: "a", name: "A", chapterNumbers: [])
        var b = FakeSource(id: "b", name: "B", chapterNumbers: []); b.failSearch = true
        let c = FakeSource(id: "c", name: "C", chapterNumbers: [])
        let service = LibraryService(store: db, registry: SourceRegistry(sources: [a, b, c]))
        let results = await service.globalSearch("Berserk", sourceIds: ["c", "a", "b", "inexistente"], concurrency: 2)
        XCTAssertEqual(results.map(\.sourceId), ["c", "a", "b"])
        XCTAssertEqual(results[0].items.first?.title, "Berserk em C")
        XCTAssertNotNil(results[2].error)
    }
}
