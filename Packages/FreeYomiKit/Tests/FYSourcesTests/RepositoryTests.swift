import XCTest
@testable import FYSources
import FYCore
import FYDomain

final class RepositoryURLTests: XCTestCase {
    func testNormalizeAcceptsHTTPSAndAddsScheme() throws {
        XCTAssertEqual(try RepositoryURL.normalize("  github.com/FelipeGFA/extensoes/raw/repo/index.pb \n"),
                       "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb")
        XCTAssertEqual(try RepositoryURL.normalize("https://RAW.githubusercontent.com/keiyoushi/extensions/repo/index.pb#x"),
                       "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb")
    }

    /// Teste obrigatório 3: URLs inválidas ou perigosas são recusadas.
    func testNormalizeRejectsUnsafeOrIncomplete() {
        XCTAssertThrowsError(try RepositoryURL.normalize("http://exemplo.com/index.pb")) {
            XCTAssertTrue($0.localizedDescription.contains("HTTPS"), "\($0)")
        }
        XCTAssertThrowsError(try RepositoryURL.normalize(""))
        XCTAssertThrowsError(try RepositoryURL.normalize("https://exemplo.com"))
        for dangerous in ["file:///etc/passwd", "javascript:alert(1)", "JavaScript:alert(1)",
                          "data:text/html,<script>alert(1)</script>", "ftp://exemplo.com/index.min.json",
                          "content://x/index.json"] {
            XCTAssertThrowsError(try RepositoryURL.normalize(dangerous), dangerous)
            XCTAssertThrowsError(try RepositoryURL.normalize(dangerous, allowHTTP: true), dangerous)
        }
        XCTAssertThrowsError(try RepositoryURL.normalize("https://usuario:senha@exemplo.com/index.min.json")) {
            XCTAssertTrue($0.localizedDescription.contains("senha"))
        }
        XCTAssertThrowsError(try RepositoryURL.normalize("https://exemplo.com/index min.json"))
        XCTAssertThrowsError(try RepositoryURL.normalize("https://exemplo.com/" + String(repeating: "a", count: 3000)))
    }

    func testNormalizeAcceptsAllIndexFormatsAndExplicitHTTP() throws {
        XCTAssertEqual(try RepositoryURL.normalize("https://exemplo.com/repo/index.min.json"),
                       "https://exemplo.com/repo/index.min.json")
        XCTAssertEqual(try RepositoryURL.normalize("exemplo.com:8443/repo/index.json"),
                       "https://exemplo.com:8443/repo/index.json", "host:porta não é confundido com esquema")
        XCTAssertEqual(try RepositoryURL.normalize("http://192.168.0.5:8080/index.min.json", allowHTTP: true),
                       "http://192.168.0.5:8080/index.min.json")
        XCTAssertTrue(RepositoryURL.isInsecure("http://192.168.0.5:8080/index.min.json"))
        XCTAssertTrue(RepositoryURL.same("http://exemplo.com/index.pb", "https://exemplo.com/index.pb"))
    }

    func testGitHubRawFormsAreTheSameRepository() {
        let a = "https://github.com/keiyoushi/extensions/raw/repo/index.pb"
        let b = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"
        let c = "https://github.com/Keiyoushi/Extensions/raw/refs/heads/repo/index.pb"
        XCTAssertTrue(RepositoryURL.same(a, b))
        XCTAssertTrue(RepositoryURL.same(a, c))
        XCTAssertFalse(RepositoryURL.same(a, "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb"))
        XCTAssertEqual(RepositoryURL.displayName(a), "keiyoushi/extensions")
    }

    func testSyncPlanMergesWithoutDuplicates() {
        let local = [
            "https://github.com/keiyoushi/extensions/raw/repo/index.pb",
            "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb",
            "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb", // duplicata
        ]
        let server = [
            ExtensionRepository(indexURL: "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb", name: "Keiyoushi"),
            ExtensionRepository(indexURL: "https://example.org/outro/index.pb", name: "Outro"),
        ]
        let plan = RepositorySync.plan(local: local, server: server)
        XCTAssertEqual(plan.addToServer, ["https://github.com/FelipeGFA/extensoes/raw/repo/index.pb"])
        XCTAssertEqual(plan.mergedLocal, [local[0], local[1], "https://example.org/outro/index.pb"])
    }

    func testRepositoryFromIndexAndSafeLinks() throws {
        let (_, data) = try ExtensionIndexDecoder.detect(try fixture())
        let index = try ExtensionIndexDecoder.decodeStore(data)
        let repo = ExtensionRepository(indexURL: "https://repo.example/index.pb", index: index)
        XCTAssertEqual(repo.name, "Keiyoushi")
        XCTAssertEqual(repo.badgeLabel, "KEI")
        XCTAssertEqual(repo.extensionCount, 10)
        XCTAssertEqual(repo.websiteURL?.host, "keiyoushi.github.io")
        XCTAssertEqual(repo.signingKeyFingerprint?.count, 19) // "AAAA BBBB CCCC DDDD"
        var bad = repo
        bad.discord = "javascript:alert(1)"
        XCTAssertNil(bad.discordURL, "só links HTTPS são abertos")
    }
}

final class MultiRepositoryCatalogTests: XCTestCase {
    var cacheDir: URL!
    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-repos-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cacheDir) }

    func testRefreshAllKeepsOrderIsolatesFailuresAndCachesPerRepository() async throws {
        let http = StubHTTP()
        http.responses["https://a.example/index.pb"] = .success(HTTPResponse(statusCode: 200, body: try fixture()))
        http.responses["https://b.example/index.pb"] = .success(HTTPResponse(statusCode: 404, body: Data()))
        http.responses["https://c.example/index.pb"] = .success(HTTPResponse(statusCode: 200, body: try fixture()))
        let client = ExtensionCatalogClient(http: http, cacheDirectory: cacheDir)
        let urls = ["https://a.example/index.pb", "https://b.example/index.pb", "https://c.example/index.pb"]
        let all = await client.refreshAll(urls)
        XCTAssertEqual(all.map(\.indexURL), urls)
        XCTAssertNotNil(all[0].snapshot)
        XCTAssertNil(all[1].snapshot)
        XCTAssertTrue(all[1].error?.contains("404") ?? false)
        XCTAssertEqual(all[1].repository.name, "b.example")
        XCTAssertEqual(all[2].repository.name, "Keiyoushi")

        // Cache separado por repositório: remover um não apaga o outro.
        client.removeCache(for: urls[0])
        let cached = client.cachedAll(urls)
        XCTAssertNil(cached[0].snapshot)
        XCTAssertNil(cached[1].snapshot)
        XCTAssertNotNil(cached[2].snapshot)
    }
}

final class SuwayomiRepositoryTests: XCTestCase {
    let base = "http://192.168.0.10:4567"

    func client(_ stub: StubHTTP) -> SuwayomiClient {
        SuwayomiClient(config: SuwayomiConfig(baseURL: URL(string: base)!, allowInsecureHTTP: true), http: stub)
    }

    func testListsServerRepositories() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/graphql", """
        {"data":{"extensionStores":{"nodes":[
          {"name":"Keiyoushi","badgeLabel":"KEI","signingKey":"9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2",
           "contactWebsite":"https://keiyoushi.github.io","contactDiscord":"https://discord.gg/exemplo",
           "indexUrl":"https://github.com/keiyoushi/extensions/raw/repo/index.pb","extensions":{"totalCount":1312}},
          {"name":"","badgeLabel":"","signingKey":"","contactWebsite":"","contactDiscord":null,
           "indexUrl":"https://github.com/FelipeGFA/extensoes/raw/repo/index.pb","extensions":{"totalCount":40}}]}}}
        """)
        let repos = try await client(stub).extensionStores()
        XCTAssertEqual(repos.count, 2)
        XCTAssertEqual(repos[0].name, "Keiyoushi")
        XCTAssertEqual(repos[0].badgeLabel, "KEI")
        XCTAssertEqual(repos[0].extensionCount, 1312)
        XCTAssertEqual(repos[0].discordURL?.host, "discord.gg")
        XCTAssertEqual(repos[1].name, "FelipeGFA/extensoes", "sem nome: usa dono/repositório")
        XCTAssertNil(repos[1].website)
        let body = String(decoding: stub.requests.last?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("extensionStores"))
    }

    func testRemoveSendsIndexURLAsVariable() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/graphql", #"{"data":{"removeExtensionStore":{"extensionStore":{"indexUrl":"x"}}}}"#)
        try await client(stub).removeExtensionStore(indexURL: "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb")
        let json = try JSONSerialization.jsonObject(with: stub.requests.last?.body ?? Data()) as? [String: Any]
        XCTAssertTrue((json?["query"] as? String)?.contains("removeExtensionStore") ?? false)
        XCTAssertEqual((json?["variables"] as? [String: String])?["url"],
                       "https://github.com/FelipeGFA/extensoes/raw/repo/index.pb",
                       "o endereço vai como variável, nunca concatenado na consulta")
    }

    func testGraphQLErrorsAreSurfaced() async {
        let stub = StubHTTP()
        stub.json("\(base)/api/graphql", #"{"errors":[{"message":"Failed to fetch extension store"}],"data":null}"#)
        do {
            try await client(stub).addExtensionStore(indexURL: "https://exemplo.com/index.pb")
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Failed to fetch extension store"))
        }
    }

    func testExtensionStoreIndexMapsPackages() async throws {
        let stub = StubHTTP()
        stub.json("\(base)/api/graphql", """
        {"data":{"extensions":{"nodes":[
          {"pkgName":"eu.kanade.tachiyomi.extension.pt.sussyscan","storeIndexUrl":"https://github.com/keiyoushi/extensions/raw/repo/index.pb"},
          {"pkgName":"eu.kanade.tachiyomi.extension.all.local","storeIndexUrl":null}]}}}
        """)
        let map = try await client(stub).extensionStoreIndex()
        XCTAssertEqual(map.count, 1)
        XCTAssertNotNil(map["eu.kanade.tachiyomi.extension.pt.sussyscan"])
    }
}

final class RepositorySettingsMigrationTests: XCTestCase {
    func testOldSingleCatalogURLBecomesList() throws {
        let old = #"{"catalogURL":"https://github.com/FelipeGFA/extensoes/raw/repo/index.pb"}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.extensionRepositories, ["https://github.com/FelipeGFA/extensoes/raw/repo/index.pb"])
        let fresh = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.extensionRepositories, [], "nenhum repositório de fábrica")
        XCTAssertEqual(AppSettings().extensionRepositories, [])
        XCTAssertEqual(AppSettings().catalogURL, "")
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(roundTrip.extensionRepositories, s.extensionRepositories)
    }
}

final class RepositoryDeepLinkTests: XCTestCase {
    func testParsesMihonStyleLinks() {
        let target = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb"
        let enc = target.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(RepositoryDeepLink.parse(URL(string: "tachiyomi://add-repo?url=\(enc)")!), target)
        XCTAssertEqual(RepositoryDeepLink.parse(URL(string: "mihon://extension-store?url=\(enc)")!), target)
        XCTAssertEqual(RepositoryDeepLink.parse(URL(string: "freeyomi://add-repo?url=\(enc)")!), target)
    }

    func testRejectsOtherHostsAndUnsafeTargets() {
        XCTAssertNil(RepositoryDeepLink.parse(URL(string: "tachiyomi://outra-coisa?url=https://x.org/index.pb")!))
        XCTAssertNil(RepositoryDeepLink.parse(URL(string: "tachiyomi://add-repo?url=http://x.org/index.pb")!))
        XCTAssertNil(RepositoryDeepLink.parse(URL(string: "tachiyomi://add-repo")!))
        XCTAssertNil(RepositoryDeepLink.parse(URL(fileURLWithPath: "/tmp/livro.cbz")))
    }
}
