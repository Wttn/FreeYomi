import XCTest
@testable import FYSources
import FYCore
import FYDomain

private func png(_ seed: UInt8) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]); d.append(Data(repeating: seed, count: 40)); return d
}

final class LocalImportTests: XCTestCase {
    var tmp: URL!
    var store: LocalLibraryStore!
    var importer: LocalImporter!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = LocalLibraryStore(root: tmp.appendingPathComponent("LocalFiles"))
        importer = LocalImporter(store: store)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: tmp) }

    func makeZip(_ name: String, _ files: [(String, Data)]) throws -> URL {
        var w = ZipWriter()
        for (p, d) in files { try w.add(path: p, data: d) }
        let u = tmp.appendingPathComponent(name)
        try w.finish().write(to: u)
        return u
    }

    /// Critério 3: importar um arquivo local compatível.
    func testImportCBZWithComicInfoAndNaturalOrder() throws {
        let info = Data("""
        <?xml version="1.0"?><ComicInfo><Series>Minha Série</Series><Number>3</Number>
        <Writer>Autora</Writer><Summary>Resumo &amp; mais</Summary></ComicInfo>
        """.utf8)
        let url = try makeZip("serie-03.cbz", [
            ("p10.png", png(10)), ("p2.png", png(2)), ("p1.png", png(1)),
            ("ComicInfo.xml", info), ("leiame.txt", Data("oi".utf8)), ("falsa.jpg", Data("não sou imagem".utf8)),
            ("__MACOSX/._p1.png", png(9)), ("../fuga.png", png(7)),
        ])
        let result = try importer.importItem(at: url)
        let m = result.manifest
        XCTAssertEqual(m.title, "Minha Série")
        XCTAssertEqual(m.author, "Autora")
        XCTAssertEqual(m.summary, "Resumo & mais")
        XCTAssertEqual(m.chapters.count, 1)
        XCTAssertEqual(m.chapters[0].name, "Capítulo 3")
        XCTAssertEqual(m.chapters[0].number, 3)
        XCTAssertEqual(m.chapters[0].pages.count, 3)
        // Ordem natural: p1, p2, p10 → conteúdo correspondente
        let first = try Data(contentsOf: store.root.appendingPathComponent(m.id).appendingPathComponent(m.chapters[0].pages[0]))
        let last = try Data(contentsOf: store.root.appendingPathComponent(m.id).appendingPathComponent(m.chapters[0].pages[2]))
        XCTAssertEqual(first, png(1))
        XCTAssertEqual(last, png(10))
        XCTAssertTrue(result.skipped.contains { $0.contains("fuga") }, "zip slip ignorado e relatado")
        XCTAssertTrue(result.skipped.contains { $0.contains("falsa.jpg") })
        // Nada foi gravado fora da pasta do título
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("fuga.png").path))
        XCTAssertEqual(store.all().map(\.id), [m.id])
    }

    func testVolumeWithChapterFoldersBecomesChapters() throws {
        let url = try makeZip("Vol 1.zip", [
            ("Cap 10/01.png", png(1)), ("Cap 2/01.png", png(2)), ("Cap 2/02.png", png(3)),
        ])
        let m = try importer.importItem(at: url).manifest
        XCTAssertEqual(m.title, "Vol 1")
        XCTAssertEqual(m.chapters.map(\.name), ["Cap 2", "Cap 10"])
        XCTAssertEqual(m.chapters.map(\.number), [2, 10])
        XCTAssertEqual(m.chapters.map(\.pages.count), [2, 1])
    }

    func testFolderOfArchivesAndImageFolders() throws {
        let series = tmp.appendingPathComponent("Série X")
        try FileManager.default.createDirectory(at: series.appendingPathComponent("Capítulo 1"), withIntermediateDirectories: true)
        try png(1).write(to: series.appendingPathComponent("Capítulo 1/a.png"))
        try png(2).write(to: series.appendingPathComponent("Capítulo 1/b.png"))
        var w = ZipWriter(); try w.add(path: "x.png", data: png(3))
        try w.finish().write(to: series.appendingPathComponent("Capítulo 2.cbz"))
        let m = try importer.importItem(at: series).manifest
        XCTAssertEqual(m.title, "Série X")
        XCTAssertEqual(m.chapters.map(\.name), ["Capítulo 1", "Capítulo 2"])
        XCTAssertEqual(m.pageCount, 3)
    }

    func testImageEPUBInSpineOrder() throws {
        let container = Data("""
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.utf8)
        let opf = Data("""
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <metadata><dc:title>Quadrinho EPUB</dc:title><dc:creator>Fulana</dc:creator></metadata>
        <manifest><item id="p1" href="Text/p1.xhtml" media-type="application/xhtml+xml"/>
        <item id="p2" href="Text/p2.xhtml" media-type="application/xhtml+xml"/>
        <item id="i1" href="Images/b.png" media-type="image/png"/><item id="i2" href="Images/a.png" media-type="image/png"/></manifest>
        <spine><itemref idref="p1"/><itemref idref="p2"/></spine></package>
        """.utf8)
        let x1 = Data(#"<html><body><img src="../Images/b.png" alt=""/></body></html>"#.utf8)
        let x2 = Data(#"<html><body><svg><image xlink:href="../Images/a.png"/></svg></body></html>"#.utf8)
        let url = try makeZip("q.epub", [
            ("mimetype", Data("application/epub+zip".utf8)), ("META-INF/container.xml", container),
            ("OEBPS/content.opf", opf), ("OEBPS/Text/p1.xhtml", x1), ("OEBPS/Text/p2.xhtml", x2),
            ("OEBPS/Images/a.png", png(1)), ("OEBPS/Images/b.png", png(2)),
        ])
        let m = try importer.importItem(at: url).manifest
        XCTAssertEqual(m.title, "Quadrinho EPUB")
        XCTAssertEqual(m.author, "Fulana")
        XCTAssertEqual(m.pageCount, 2)
        let firstPage = try Data(contentsOf: store.root.appendingPathComponent(m.id).appendingPathComponent(m.chapters[0].pages[0]))
        XCTAssertEqual(firstPage, png(2), "ordem do spine (b antes de a), não alfabética")
    }

    func testTextOnlyEPUBIsRejectedClearly() throws {
        let container = Data(#"<container><rootfiles><rootfile full-path="c.opf"/></rootfiles></container>"#.utf8)
        let opf = Data(#"<package><manifest><item id="t" href="t.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="t"/></spine></package>"#.utf8)
        let url = try makeZip("livro.epub", [("META-INF/container.xml", container), ("c.opf", opf),
                                               ("t.xhtml", Data("<html><p>texto</p></html>".utf8))])
        XCTAssertThrowsError(try importer.importItem(at: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("EPUB de texto"))
        }
        XCTAssertTrue(store.all().isEmpty, "falha não deixa lixo")
    }

    func testDuplicatesAreDetected() throws {
        let url = try makeZip("um.cbz", [("1.png", png(1))])
        let a = try importer.importItem(at: url)
        let b = try importer.importItem(at: url)
        XCTAssertFalse(a.wasDuplicate)
        XCTAssertTrue(b.wasDuplicate)
        XCTAssertEqual(a.manifest.id, b.manifest.id)
        XCTAssertEqual(store.all().count, 1)
    }

    func testUnsupportedAndEmptyInputs() throws {
        let rar = tmp.appendingPathComponent("x.cbr")
        try Data("Rar!".utf8).write(to: rar)
        XCTAssertThrowsError(try importer.importItem(at: rar)) { XCTAssertTrue($0.localizedDescription.contains("RAR")) }
        let noImages = try makeZip("vazio.cbz", [("a.txt", Data("x".utf8))])
        XCTAssertThrowsError(try importer.importItem(at: noImages))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testLocalSourceServesPagesAndDeletion() async throws {
        let m = try importer.importItem(at: try makeZip("s.cbz", [("1.png", png(1)), ("2.png", png(2))])).manifest
        let source = LocalSource(store: store)
        let list = try await source.popular(page: 1)
        XCTAssertEqual(list.items.map(\.key), [m.id])
        XCTAssertNotNil(list.items[0].coverURL.flatMap(LocalSource.relativePath(fromCoverURL:)))
        let chapters = try await source.chapters(for: list.items[0])
        let pages = try await source.pages(mangaKey: m.id, chapterKey: chapters[0].key)
        XCTAssertEqual(pages.count, 2)
        guard case .file(let rel) = pages[1].image, let file = store.fileURL(relativePath: rel) else {
            return XCTFail("página local esperada")
        }
        XCTAssertEqual(try Data(contentsOf: file), png(2))
        XCTAssertNil(store.fileURL(relativePath: "../../segredo"))

        try store.delete(id: m.id)
        do {
            _ = try await source.pages(mangaKey: m.id, chapterKey: chapters[0].key)
            XCTFail("deveria informar que os arquivos foram removidos")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("removidos"))
        }
    }
}
