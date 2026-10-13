import XCTest
@testable import FYSources
import FYCore
import FYDomain

final class SuwayomiTests: XCTestCase {
    let base = "http://192.168.0.10:4567"

    func client(_ stub: StubHTTP) -> SuwayomiClient {
        SuwayomiClient(config: SuwayomiConfig(baseURL: URL(string: base)!, allowInsecureHTTP: true), http: stub)
    }

    func testNormalizeAddress() {
        XCTAssertEqual(SuwayomiConfig.normalize("192.168.0.10:4567/")?.absoluteString, "http://192.168.0.10:4567")
        XCTAssertEqual(SuwayomiConfig.normalize("https://user:pw@meu.servidor.com/sub/")?.absoluteString,
                       "https://meu.servidor.com/sub")
        XCTAssertNil(SuwayomiConfig.normalize("ftp://x"))
        XCTAssertNil(SuwayomiConfig.normalize("  "))
    }

    func testPersonalServerPolicyRestrictsHostAndScheme() throws {
        let policy = RequestPolicy.personalServer(base: URL(string: base)!, allowHTTP: true)
        XCTAssertNoThrow(try policy.validate(URL(string: "\(base)/api/v1/source/list")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "http://outro.host:4567/api")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "http://192.168.0.10:9999/api")!))
        let strict = RequestPolicy.personalServer(base: URL(string: base)!, allowHTTP: false)
        XCTAssertThrowsError(try strict.validate(URL(string: "\(base)/api")!), "HTTP só com permissão explícita")
        XCTAssertEqual(SuwayomiConfig(baseURL: URL(string: base)!, username: "eu", password: "s3nha").authHeaders["Authorization"],
                       "Basic " + Data("eu:s3nha".utf8).base64EncodedString())
    }

    func testExtensionsAndSources() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/v1/extension/list", """
        [{"repo":"https://x","apkName":"a.apk","iconUrl":"/api/v1/extension/icon/eu.kanade.tachiyomi.extension.pt.exemplo",
          "name":"Exemplo","pkgName":"eu.kanade.tachiyomi.extension.pt.exemplo","versionName":"1.4.2","versionCode":2,
          "lang":"pt-BR","isNsfw":false,"installed":true,"hasUpdate":true,"obsolete":false}]
        """)
        stub.json("\(base)/api/v1/source/list", """
        [{"id":"0","name":"Local source","lang":"localsourcelang","iconUrl":"","supportsLatest":false,"isConfigurable":false,"isNsfw":false,"displayName":"Local source","baseUrl":null},
         {"id":"6247824327199706550","name":"Exemplo","lang":"pt-BR","iconUrl":"/api/v1/extension/icon/x","supportsLatest":true,"isConfigurable":false,"isNsfw":false,"displayName":"Exemplo (PT-BR)","baseUrl":"https://exemplo.org"}]
        """)
        stub.json("\(base)/api/v1/extension/install/", "")
        let c = client(stub)
        let exts = try await c.extensions()
        XCTAssertEqual(exts.first?.hasUpdate, true)
        XCTAssertEqual(c.absolute(exts[0].iconUrl), "\(base)/api/v1/extension/icon/eu.kanade.tachiyomi.extension.pt.exemplo")
        let sources = try await c.sources()
        XCTAssertEqual(sources.map(\.id), ["6247824327199706550"], "a fonte local do servidor é ocultada")
        try await c.install("eu.kanade.tachiyomi.extension.pt.exemplo")
        XCTAssertTrue(stub.requested.contains("\(base)/api/v1/extension/install/eu.kanade.tachiyomi.extension.pt.exemplo"))
    }

    func testBrowseChaptersAndPagesThroughServer() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/v1/source/123/popular/1", """
        {"mangaList":[{"id":7,"sourceId":"123","url":"/obra","title":"Obra","thumbnailUrl":"/api/v1/manga/7/thumbnail",
          "initialized":true,"genre":["Ação"],"status":"ONGOING","inLibrary":false,"extraField":42}],"hasNextPage":true}
        """)
        stub.json("\(base)/api/v1/manga/7/chapters", """
        [{"id":1,"url":"/c1","name":"Cap 1","uploadDate":1700000000000,"chapterNumber":1.0,"scanlator":"Grupo","mangaId":7,"index":1,"fetchedAt":0,"downloaded":false,"pageCount":-1},
         {"id":2,"url":"/c2","name":"Cap 2","uploadDate":0,"chapterNumber":2.0,"scanlator":"","mangaId":7,"index":2,"fetchedAt":0,"downloaded":false}]
        """)
        stub.json("\(base)/api/v1/manga/7/chapter/1", """
        {"id":1,"url":"/c1","name":"Cap 1","uploadDate":0,"chapterNumber":1.0,"scanlator":null,"mangaId":7,"index":1,"fetchedAt":0,"downloaded":false,"pageCount":3}
        """)
        let source = SuwayomiSource(info: SuwayomiSourceInfo(id: "123", name: "Ex", lang: "pt-BR", displayName: "Exemplo",
                                                             iconUrl: "", supportsLatest: true, isNsfw: false),
                                    client: client(stub))
        XCTAssertEqual(source.id, "suwayomi:123")
        let list = try await source.popular(page: 1)
        XCTAssertTrue(list.hasNextPage)
        XCTAssertEqual(list.items[0].coverURL, "\(base)/api/v1/manga/7/thumbnail")
        XCTAssertEqual(list.items[0].status, .ongoing)
        let chapters = try await source.chapters(for: list.items[0])
        XCTAssertEqual(chapters.map(\.name), ["Cap 2", "Cap 1"], "mais recente primeiro")
        XCTAssertNil(chapters[0].scanlator, "scanlator vazio vira nil")
        XCTAssertNotNil(chapters[1].uploadDate)
        let pages = try await source.pages(mangaKey: "7", chapterKey: chapters[1].key)
        XCTAssertEqual(pages.count, 3)
        guard case .remote(let url, _) = pages[2].image else { return XCTFail() }
        XCTAssertEqual(url, "\(base)/api/v1/manga/7/chapter/1/page/2")
    }

    func testServerErrorsAreUnderstandable() async {
        let stub = StubHTTP()
        stub.json("\(base)/api/v1/extension/list", "", status: 401)
        do {
            _ = try await client(stub).extensions()
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("usuário e senha"))
        }
    }

    func testAddExtensionStoreSendsGraphQL() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/graphql", #"{"data":{"addExtensionStore":{"extensionStore":{"name":"Keiyoushi"}}}}"#)
        try await client(stub).addExtensionStore(indexURL: "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb")
        let req = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(req.method, "POST")
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("addExtensionStore"))
        XCTAssertTrue(body.contains("keiyoushi"))
    }
}

final class MangaDexTests: XCTestCase {
    let api = "https://api.mangadex.org"

    func source(_ stub: StubHTTP, adult: Bool = false) -> MangaDexSource {
        MangaDexSource(language: "pt-br", includeAdult: adult, http: stub,
                       limiter: RateLimiter(requestsPerSecond: 1000), atHomeLimiter: RateLimiter(requestsPerSecond: 1000))
    }

    let mangaJSON = """
    {"result":"ok","response":"collection","data":[{"id":"a1c7c817-4e59-43b7-9365-09675a149a6f","type":"manga",
     "attributes":{"title":{"ja-ro":"One Piece"},"altTitles":[{"ja":"ワンピース"},{"pt-br":"One Piece (BR)"}],
     "description":{"en":"EN","pt-br":"PT"},"status":"ongoing",
     "tags":[{"id":"t","type":"tag","attributes":{"name":{"en":"Action"},"group":"genre"},"relationships":[]}],
     "contentRating":"suggestive"},
     "relationships":[{"id":"au","type":"author","attributes":{"name":"Oda Eiichiro"}},
                      {"id":"cv","type":"cover_art","attributes":{"fileName":"capa.png"}},{"id":"m","type":"manga","related":"doujinshi"}]}],
     "limit":30,"offset":0,"total":36}
    """

    func testSearchMapsTitleCoverAndQuery() async throws {
        let stub = StubHTTP()
        stub.json("\(api)/manga?", mangaJSON)
        let r = try await source(stub).search(query: "one piece", page: 1)
        let m = try XCTUnwrap(r.items.first)
        XCTAssertEqual(m.title, "One Piece (BR)", "usa o título no idioma escolhido quando existe")
        XCTAssertEqual(m.author, "Oda Eiichiro")
        XCTAssertEqual(m.summary, "PT")
        XCTAssertEqual(m.genres, ["Action"])
        XCTAssertEqual(m.coverURL, "https://uploads.mangadex.org/covers/a1c7c817-4e59-43b7-9365-09675a149a6f/capa.png.256.jpg")
        XCTAssertTrue(r.hasNextPage)
        let url = try XCTUnwrap(stub.requests.last?.url.absoluteString)
        XCTAssertTrue(url.contains("title=one%20piece"))
        XCTAssertTrue(url.contains("availableTranslatedLanguage%5B%5D=pt-br") || url.contains("availableTranslatedLanguage[]=pt-br"))
        XCTAssertFalse(url.contains("erotica"), "conteúdo adulto desativado por padrão")
        XCTAssertFalse(url.contains("pornographic"))
    }

    func testChaptersSkipExternalAndCreditGroups() async throws {
        let stub = StubHTTP()
        stub.json("\(api)/manga/abc/feed", """
        {"result":"ok","data":[
         {"id":"c1195","type":"chapter","attributes":{"volume":null,"chapter":"1195","title":"Fraqueza","translatedLanguage":"pt-br",
          "externalUrl":"https://mangaplus.shueisha.co.jp/viewer/5001226","publishAt":"2026-10-11T15:10:55+00:00","pages":0},
          "relationships":[{"type":"scanlation_group","attributes":{"name":"MangaPlus"}}]},
         {"id":"c1194","type":"chapter","attributes":{"volume":"110","chapter":"1194","title":"","translatedLanguage":"pt-br",
          "externalUrl":null,"publishAt":"2026-10-04T15:10:55+00:00","pages":17},
          "relationships":[{"type":"scanlation_group","attributes":{"name":"Grupo A"}},{"type":"scanlation_group","attributes":{"name":"Grupo B"}},{"type":"user"}]}
        ],"limit":500,"offset":0,"total":2}
        """)
        let chapters = try await source(stub).chapters(for: SourceManga(key: "abc", title: "X"))
        XCTAssertEqual(chapters.count, 1, "capítulos só externos não são legíveis no app")
        XCTAssertEqual(chapters[0].name, "Vol. 110 Cap. 1194")
        XCTAssertEqual(chapters[0].number, 1194)
        XCTAssertEqual(chapters[0].scanlator, "Grupo A & Grupo B")
        XCTAssertNotNil(chapters[0].uploadDate)
    }

    func testPagesFromAtHomeWithReportMarker() async throws {
        let stub = StubHTTP()
        stub.json("\(api)/at-home/server/c1194", """
        {"result":"ok","baseUrl":"https://xyz.abc.mangadex.network:443/token","chapter":{"hash":"h4sh","data":["1.png","2.png"],"dataSaver":["1.jpg","2.jpg"]}}
        """)
        let pages = try await source(stub).pages(mangaKey: "abc", chapterKey: "c1194")
        XCTAssertEqual(pages.count, 2)
        guard case .remote(let url, let headers) = pages[1].image else { return XCTFail() }
        XCTAssertEqual(url, "https://xyz.abc.mangadex.network:443/token/data/h4sh/2.png")
        XCTAssertEqual(headers[MangaDexReporter.marker], "1", "nós MangaDex@Home exigem relatório")
    }

    func testRateLimitIsReportedClearly() async {
        let stub = StubHTTP()
        stub.json("\(api)/manga?", "{}", status: 429)
        do {
            _ = try await source(stub).popular(page: 1)
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("aguarde"))
        }
    }

    func testRateLimiterSpacesRequests() async throws {
        let limiter = RateLimiter(requestsPerSecond: 20)
        let start = Date()
        for _ in 0..<5 { try await limiter.wait() }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.18)
    }
}
