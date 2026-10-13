import XCTest
@testable import FYSources
import FYCore
import FYDomain
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Cliente HTTP falso para testes sem rede.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    var responses: [String: Result<HTTPResponse, Error>] = [:]
    var requested: [String] = []
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requested.append(url.absoluteString)
        guard let r = responses[url.absoluteString] else { throw FYError.network("sem rota") }
        return try r.get()
    }
}

func fixture() throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "keiyoushi-index-sample.pb", withExtension: "gz",
                                              subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class CatalogDecoderTests: XCTestCase {
    /// Critério 7: o catálogo é decodificado corretamente (amostra real do index.pb).
    func testDecodesRealSample() throws {
        let (format, data) = try ExtensionIndexDecoder.detect(try fixture())
        XCTAssertEqual(format, .protobuf)
        let store = try ExtensionIndexDecoder.decodeStore(data)
        XCTAssertEqual(store.name, "Keiyoushi")
        XCTAssertEqual(store.badgeLabel, "KEI")
        XCTAssertEqual(store.signingKey.count, 64)
        XCTAssertEqual(store.website, "https://keiyoushi.github.io")
        XCTAssertEqual(store.extensions.count, 10)

        let plus = try XCTUnwrap(store.extensions.first { $0.packageName.hasSuffix(".mangaplus") })
        XCTAssertEqual(plus.name, "MANGA Plus by SHUEISHA")
        XCTAssertEqual(plus.contentWarning, .safe)
        XCTAssertEqual(plus.extensionLib, "1.6")
        XCTAssertTrue(plus.apkURL.hasSuffix(".apk"))
        XCTAssertEqual(plus.jarURL?.hasSuffix(".jar"), true)
        XCTAssertGreaterThan(plus.sources.count, 1)
        XCTAssertTrue(plus.languages.contains("en"))
        XCTAssertNotEqual(plus.sources[0].id, 0)
        XCTAssertEqual(plus.packageLanguage, "all")
    }

    /// Critério 8: extensões incompatíveis são identificadas sem falhas.
    func testAllCatalogExtensionsRequireAndroidUntilAdapterExists() throws {
        let store = try ExtensionIndexDecoder.decodeStore(try ExtensionIndexDecoder.detect(try fixture()).1)
        for e in store.extensions {
            XCTAssertEqual(CompatibilityResolver.resolve(e), .requiresAndroid)
        }
    }

    func testSyntheticIndexWithUnknownFieldsAndNSFW() throws {
        var w = ProtobufWriter()
        w.string(1, "Repo Teste")
        w.string(2, "TST")
        w.string(3, "abc")
        w.message(4) { $0.string(1, "https://exemplo.org") }
        w.string(999, "campo futuro desconhecido")
        w.message(101) { list in
            list.message(1) { e in
                e.string(1, "Exemplo")
                e.string(2, "eu.kanade.tachiyomi.extension.pt.exemplo")
                e.message(3) { $0.string(1, "https://x/a.apk"); $0.string(2, "https://x/i.png") }
                e.string(4, "1.4")
                e.varint(5, 14001)
                e.string(6, "1.4.1")
                e.varint(7, 3)
                e.message(8) { s in
                    s.int64(1, -5); s.string(2, "Exemplo"); s.string(3, "pt-BR")
                    s.string(4, "https://exemplo.org"); s.string(5, "https://m1"); s.string(5, "https://m2")
                    s.string(7, "Aviso da fonte")
                }
                e.varint(77, 1)
            }
        }
        let gz = try Gzip.compress(w.data)
        let store = try ExtensionIndexDecoder.decodeStore(try ExtensionIndexDecoder.detect(gz).1)
        let e = try XCTUnwrap(store.extensions.first)
        XCTAssertEqual(e.contentWarning, .nsfw)
        XCTAssertEqual(e.packageLanguage, "pt")
        XCTAssertEqual(e.sources[0].id, -5)
        XCTAssertEqual(e.sources[0].mirrorURLs, ["https://m1", "https://m2"])
        XCTAssertEqual(e.sources[0].message, "Aviso da fonte")
        XCTAssertNil(e.jarURL)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try ExtensionIndexDecoder.decodeStore(Data([0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try ExtensionIndexDecoder.detect(Data()))
    }

    func testDetectsLegacyFormats() throws {
        XCTAssertEqual(try ExtensionIndexDecoder.detect(Data("[]".utf8)).0, .legacyList)
        XCTAssertEqual(try ExtensionIndexDecoder.detect(Data(#"{"index_v2":"https://a/b.pb"}"#.utf8)).0,
                       .repoJSON(indexV2: "https://a/b.pb"))
    }
}

final class CatalogClientTests: XCTestCase {
    var cacheDir: URL!
    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-cat-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cacheDir) }

    func testFollowsRepoJSONAndCaches() async throws {
        let http = StubHTTP()
        http.responses["https://repo.example/repo.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(#"{"index_v2":"https://repo.example/index.pb"}"#.utf8)))
        http.responses["https://repo.example/index.pb"] = .success(HTTPResponse(statusCode: 200, body: try fixture()))
        let client = ExtensionCatalogClient(http: http, cacheDirectory: cacheDir)
        let snap = try await client.refresh(from: "https://repo.example/repo.json")
        XCTAssertFalse(snap.isFromCache)
        XCTAssertEqual(snap.sourceURL, "https://repo.example/index.pb")
        XCTAssertEqual(snap.index.extensions.count, 10)

        // Sem rede: usa o cache e informa o erro (critério 10: erro compreensível).
        let offline = StubHTTP()
        let client2 = ExtensionCatalogClient(http: offline, cacheDirectory: cacheDir)
        let cached = try await client2.refresh(from: "https://repo.example/repo.json")
        XCTAssertTrue(cached.isFromCache)
        XCTAssertNotNil(cached.networkError)
        XCTAssertEqual(cached.index.extensions.count, 10)
    }

    func testHTTPErrorWithoutCacheIsReported() async {
        let http = StubHTTP()
        http.responses["https://repo.example/index.pb"] = .success(HTTPResponse(statusCode: 404, body: Data()))
        let client = ExtensionCatalogClient(http: http, cacheDirectory: cacheDir)
        do {
            _ = try await client.refresh(from: "https://repo.example/index.pb")
            XCTFail("deveria falhar")
        } catch {
            XCTAssertEqual(error as? FYError, .httpStatus(404, url: "https://repo.example/index.pb"))
            XCTAssertTrue(error.localizedDescription.contains("404"))
        }
    }

    func testRejectsPlainHTTP() async {
        let client = ExtensionCatalogClient(http: StubHTTP(), cacheDirectory: cacheDir)
        do {
            _ = try await client.refresh(from: "http://inseguro.example/index.pb")
            XCTFail("deveria recusar http")
        } catch {
            guard case .insecureURL = error as? FYError else { return XCTFail("erro inesperado \(error)") }
        }
    }

    /// Teste opcional contra o índice real. Rode com FY_LIVE_TESTS=1.
    func testLiveKeiyoushiIndex() async throws {
        guard ProcessInfo.processInfo.environment["FY_LIVE_TESTS"] == "1" else {
            throw XCTSkip("defina FY_LIVE_TESTS=1 para baixar o índice real")
        }
        let client = ExtensionCatalogClient(http: URLSessionHTTPClient(), cacheDirectory: cacheDir)
        let snap = try await client.refresh(from: AppSettings().catalogURL)
        XCTAssertFalse(snap.isFromCache)
        XCTAssertEqual(snap.index.name, "Keiyoushi")
        XCTAssertGreaterThan(snap.index.extensions.count, 500)
        let ptBR = snap.index.extensions.filter { $0.languages.contains("pt-BR") }
        XCTAssertGreaterThan(ptBR.count, 10)
        print("LIVE: \(snap.index.extensions.count) extensões, \(ptBR.count) com pt-BR")
    }
}

final class DemoSourceTests: XCTestCase {
    func testDemoCatalogIsClearlyLabeled() async throws {
        let demo = DemoSource()
        let list = try await demo.popular(page: 1)
        XCTAssertFalse(list.items.isEmpty)
        for m in list.items {
            XCTAssertTrue(m.title.hasPrefix("Demonstração"), "dados fictícios devem ser identificados")
            XCTAssertTrue(m.coverURL?.hasPrefix("freeyomi-demo://") ?? false)
        }
        let page2 = try await demo.popular(page: 2)
        XCTAssertTrue(page2.items.isEmpty)
    }

    func testChaptersAndPages() async throws {
        let demo = DemoSource()
        let m = try await demo.popular(page: 1).items[0]
        let chs = try await demo.chapters(for: m)
        XCTAssertEqual(chs.first?.number, Double(chs.count), "mais recente primeiro")
        let pages = try await demo.pages(mangaKey: m.key, chapterKey: chs.last!.key)
        XCTAssertEqual(pages.map(\.index), Array(0..<pages.count))
        guard case .demo = pages[0].image else { return XCTFail("página demo esperada") }
        do {
            _ = try await demo.pages(mangaKey: m.key, chapterKey: "inexistente")
            XCTFail("deveria falhar")
        } catch {}
    }

    func testSearch() async throws {
        let r = try await DemoSource().search(query: "marés", page: 1)
        XCTAssertEqual(r.items.count, 1)
    }

    func testRegistryListsPlannedSources() {
        let listings = SourceRegistry.makeDefault().listings()
        XCTAssertTrue(listings.contains { $0.id == .demo && $0.status == .implemented })
        XCTAssertTrue(listings.contains { $0.id == .local && $0.status == .planned })
    }
}

final class ReaderNavigationTests: XCTestCase {
    func testTapZonesRespectReadingDirection() {
        XCTAssertEqual(ReaderNavigation.zone(forRelativeX: 0.1, mode: .pagedRightToLeft, invert: false), .next)
        XCTAssertEqual(ReaderNavigation.zone(forRelativeX: 0.1, mode: .pagedLeftToRight, invert: false), .previous)
        XCTAssertEqual(ReaderNavigation.zone(forRelativeX: 0.9, mode: .pagedLeftToRight, invert: false), .next)
        XCTAssertEqual(ReaderNavigation.zone(forRelativeX: 0.5, mode: .pagedLeftToRight, invert: false), .menu)
        XCTAssertEqual(ReaderNavigation.zone(forRelativeX: 0.9, mode: .pagedLeftToRight, invert: true), .previous)
    }

    func testTargetsAndPreload() {
        XCTAssertNil(ReaderNavigation.target(from: 9, zone: .next, pageCount: 10))
        XCTAssertEqual(ReaderNavigation.target(from: 3, zone: .previous, pageCount: 10), 2)
        XCTAssertEqual(ReaderNavigation.preloadIndices(current: 7, count: 4, pageCount: 10), [8, 9])
        XCTAssertEqual(ReaderNavigation.preloadIndices(current: 9, count: 4, pageCount: 10), [])
    }
}
