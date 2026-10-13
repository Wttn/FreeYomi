import XCTest
@testable import FYData
import FYDomain

final class MigrationTests: XCTestCase {
    func testMigrateIsIdempotent() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        XCTAssertEqual(try Migrator.migrate(db), [1])
        XCTAssertEqual(try Migrator.migrate(db), [])
        XCTAssertEqual(db.userVersion, Migrator.latestVersion)
    }

    func testRefusesNewerSchema() throws {
        let db = try SQLiteDatabase(path: ":memory:")
        try db.execute("PRAGMA user_version = 999")
        XCTAssertThrowsError(try Migrator.migrate(db))
    }
}

final class PersistenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func sampleManga(_ key: String = "m/1", source: SourceID = "demo") -> Manga {
        Manga(sourceId: source, key: key, title: "Título \(key)", author: "Autor", genres: ["A", "B"], status: .ongoing)
    }

    /// Critério de aceitação 2: a biblioteca persiste após fechar e reabrir.
    func testLibrarySurvivesReopen() throws {
        let url = dir.appendingPathComponent("library.sqlite")
        do {
            let store = try DataStore.open(fileURL: url)
            let id = try store.library.upsertManga(sampleManga())
            try store.library.add(mangaId: id)
            var s = store.settings.load()
            s.theme = .dark
            s.setItemsPerRow(3)
            try store.settings.save(s)
        }
        let reopened = try DataStore.open(fileURL: url)
        XCTAssertFalse(reopened.recoveredFromCorruption)
        let items = try reopened.library.items()
        XCTAssertEqual(items.map(\.manga.title), ["Título m/1"])
        XCTAssertEqual(items.first?.manga.genres, ["A", "B"])
        XCTAssertEqual(reopened.settings.load().theme, .dark)
        XCTAssertEqual(reopened.settings.load().libraryItemsPerRow, 3)
    }

    func testCompositeKeyDistinguishesSources() throws {
        let store = try DataStore.inMemory()
        let a = try store.library.upsertManga(sampleManga("same", source: "demo"))
        let b = try store.library.upsertManga(sampleManga("same", source: "komga"))
        let again = try store.library.upsertManga(sampleManga("same", source: "demo"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, again, "upsert deve manter o ID estável")
    }

    func testChapterUpsertPreservesReadState() throws {
        let store = try DataStore.inMemory()
        let id = try store.library.upsertManga(sampleManga())
        let chs = try store.chapters.upsert([
            Chapter(mangaId: id, key: "c1", name: "Cap 1", number: 1, sourceOrder: 1),
            Chapter(mangaId: id, key: "c2", name: "Cap 2", number: 2, sourceOrder: 0),
        ], mangaId: id)
        XCTAssertEqual(chs.map(\.key), ["c1", "c2"], "ordem de leitura: mais antigo primeiro")
        try store.chapters.setRead([chs[0].id], read: true)
        let again = try store.chapters.upsert([
            Chapter(mangaId: id, key: "c1", name: "Cap 1 (renomeado)", number: 1, sourceOrder: 2),
            Chapter(mangaId: id, key: "c2", name: "Cap 2", number: 2, sourceOrder: 1),
            Chapter(mangaId: id, key: "c3", name: "Cap 3", number: 3, sourceOrder: 0),
        ], mangaId: id)
        XCTAssertEqual(again.count, 3)
        XCTAssertTrue(again[0].isRead)
        XCTAssertEqual(again[0].name, "Cap 1 (renomeado)")
        try store.library.add(mangaId: id)
        XCTAssertEqual(try store.library.items().first?.unreadCount, 2)
    }

    /// Critério 5: progresso salvo e restaurado, incluindo posição de rolagem.
    func testProgressAndHistory() throws {
        let store = try DataStore.inMemory()
        let id = try store.library.upsertManga(sampleManga())
        let ch = try store.chapters.upsert([Chapter(mangaId: id, key: "c1", name: "Cap 1")], mangaId: id)[0]
        try store.progress.save(ReadingProgress(chapterId: ch.id, mangaId: id, pageIndex: 7, pageCount: 20,
                                                scrollOffset: 0.35))
        let p = try XCTUnwrap(store.progress.progress(chapterId: ch.id))
        XCTAssertEqual(p.pageIndex, 7)
        XCTAssertEqual(p.scrollOffset, 0.35, accuracy: 0.0001)

        try store.history.record(mangaId: id, chapterId: ch.id, addingSeconds: 120)
        try store.history.record(mangaId: id, chapterId: ch.id, addingSeconds: 60)
        let hist = try store.history.recent()
        XCTAssertEqual(hist.count, 1)
        XCTAssertEqual(hist[0].entry.durationSeconds, 180)
        XCTAssertEqual(hist[0].progress?.pageIndex, 7)

        try store.progress.save(ReadingProgress(chapterId: ch.id, mangaId: id, pageIndex: 19, pageCount: 20,
                                                isFinished: true))
        XCTAssertTrue(try XCTUnwrap(store.chapters.chapter(id: ch.id)).isRead)

        try store.history.clearAll()
        XCTAssertTrue(try store.history.recent().isEmpty)
    }

    func testCategoriesAndFilters() throws {
        let store = try DataStore.inMemory()
        let cat = try store.categories.create(name: "  Favoritos ")
        XCTAssertEqual(cat.name, "Favoritos")
        XCTAssertThrowsError(try store.categories.create(name: "   "))
        let a = try store.library.upsertManga(sampleManga("a"))
        var m = sampleManga("b"); m.title = "Outro 100%"
        let b = try store.library.upsertManga(m)
        try store.library.add(mangaId: a, categoryIds: [cat.id])
        try store.library.add(mangaId: b)
        XCTAssertEqual(try store.library.items(categoryId: cat.id).map(\.manga.id), [a])
        XCTAssertEqual(try store.library.items(search: "100%").map(\.manga.id), [b])
        XCTAssertEqual(try store.library.items(search: "%").map(\.manga.id), [b], "curinga escapado")
        try store.categories.delete(id: cat.id)
        XCTAssertEqual(try store.library.items().first(where: { $0.manga.id == a })?.entry.categoryIds, [])
    }

    func testDownloadsAvoidDuplicates() throws {
        let store = try DataStore.inMemory()
        let id = try store.library.upsertManga(sampleManga())
        let ch = try store.chapters.upsert([Chapter(mangaId: id, key: "c1", name: "Cap 1")], mangaId: id)[0]
        let t1 = try store.downloads.enqueue(chapterId: ch.id, totalPages: 10)
        let t2 = try store.downloads.enqueue(chapterId: ch.id, totalPages: 10)
        XCTAssertEqual(t1.id, t2.id)
        XCTAssertEqual(try store.downloads.all().count, 1)
    }

    func testCorruptedFileIsPreservedAndRecovered() throws {
        let url = dir.appendingPathComponent("broken.sqlite")
        try Data("isto não é um banco sqlite".utf8 + Data(repeating: 7, count: 4096)).write(to: url)
        let store = try DataStore.open(fileURL: url)
        XCTAssertTrue(store.recoveredFromCorruption)
        let backup = try XCTUnwrap(store.corruptedBackupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup), "o arquivo original nunca é apagado")
        XCTAssertNoThrow(try store.library.items())
    }

    func testSettingsTolerateMissingAndInvalidFields() throws {
        let json = #"{"theme":"dark","libraryItemsPerRow":99,"reader":{"mode":"inexistente"}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.theme, .dark)
        XCTAssertEqual(s.libraryItemsPerRow, AppSettings.itemsPerRowRange.upperBound)
        XCTAssertEqual(s.reader.mode, .pagedRightToLeft)
    }
}
