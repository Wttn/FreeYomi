import XCTest
@testable import FYSources
import FYCore
import FYDomain

/// Índices de teste controlados (nenhum repositório real é usado).
enum TestIndexes {
    /// index.json: mesma estrutura do index.pb, em JSON proto3 (int64 como texto, enums pelo nome).
    static let storeJSON = """
    {
      "name": "Repo de Teste",
      "badgeLabel": "TST",
      "signingKey": "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
      "contact": {"website": "https://repo.test", "discord": "https://chat.repo.test/convite"},
      "extensionList": {"extensions": [
        {"name": "Fonte Um", "packageName": "eu.kanade.tachiyomi.extension.pt.fonteum",
         "resources": {"apkUrl": "https://repo.test/apk/um.apk", "iconUrl": "https://repo.test/icon/um.png",
                       "jarUrl": "https://repo.test/jar/um.jar"},
         "extensionLib": "1.6", "versionCode": "106004", "versionName": "1.6.4",
         "contentWarning": "CONTENT_WARNING_NSFW",
         "sources": [{"id": "6289731484943315811", "name": "Fonte Um", "language": "pt-BR", "homeUrl": "https://um.test"}]},
        {"name": "Sem pacote"},
        {"name": "Fonte Dois", "packageName": "eu.kanade.tachiyomi.extension.all.fontedois",
         "resources": {"apkUrl": "https://repo.test/apk/dois.apk", "iconUrl": ""},
         "extensionLib": "1.5", "versionCode": 3, "versionName": "1.5.3", "contentWarning": 1,
         "sources": [{"id": -7, "name": "Dois EN", "language": "en"}, {"id": "8", "name": "Dois ES", "language": "es"}]}
      ]}
    }
    """

    /// index.min.json legado.
    static let legacyList = """
    [
      {"name": "Tachiyomi: Fonte Antiga", "pkg": "eu.kanade.tachiyomi.extension.pt.antiga",
       "apk": "tachiyomi-pt.antiga-v1.4.2.apk", "lang": "pt-BR", "code": 2, "version": "1.4.2", "nsfw": 0,
       "sources": [{"name": "Fonte Antiga", "lang": "pt-BR", "id": "123", "baseUrl": "https://antiga.test", "versionId": 1}]},
      {"name": "Adulta", "pkg": "eu.kanade.tachiyomi.extension.en.adulta", "apk": "../../escape.apk",
       "lang": "en", "code": 1, "version": "1.4.1", "nsfw": 1}
    ]
    """

    static let legacyRepoMeta = """
    {"meta": {"name": "Repo Legado", "shortName": "LEG", "website": "https://legado.test",
              "signingKeyFingerprint": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"}}
    """

    /// Índice nativo do FreeYomi com uma extensão do adaptador mangadex-api-v5.
    static func freeyomi(manifestURL: String = "extensoes/org.teste.md.json", sha256: String? = nil,
                         versionCode: Int = 1, adapterVersion: Int = 1, adapter: String = "mangadex-api-v5") -> String {
        let hash = sha256.map { "\"sha256\": \"\($0)\"," } ?? ""
        return """
        {
          "format": "freeyomi.repository.v1",
          "name": "Repo Nativo",
          "badgeLabel": "NAT",
          "website": "https://nativo.test",
          "extensions": [
            {"id": "org.teste.md", "name": "Fonte MD", "versionCode": \(versionCode), "versionName": "1.0.\(versionCode)",
             "language": "pt-BR", "contentWarning": "MIXED", "iconUrl": "icones/md.png",
             "adapter": "\(adapter)", "adapterVersion": \(adapterVersion), \(hash)
             "manifestUrl": "\(manifestURL)",
             "sources": [{"id": "pt-br", "name": "Fonte MD", "language": "pt-BR"}]},
            {"id": "id inválido", "name": "Quebrada", "versionCode": 1, "adapter": "x", "adapterVersion": 1,
             "manifestUrl": "https://nativo.test/q.json"}
          ]
        }
        """
    }

    /// Manifesto `freeyomi.extension.v1` para o adaptador mangadex-api-v5.
    static func manifest(versionCode: Int = 1, api: String = "https://api.md.test",
                         covers: String = "https://covers.md.test") -> String {
        """
        {
          "format": "freeyomi.extension.v1",
          "id": "org.teste.md",
          "name": "Fonte MD",
          "versionCode": \(versionCode),
          "versionName": "1.0.\(versionCode)",
          "adapter": "mangadex-api-v5",
          "adapterVersion": 1,
          "contentWarning": "MIXED",
          "sources": [{"id": "pt-br", "name": "Fonte MD", "language": "pt-br"}],
          "config": {"apiBaseUrl": "\(api)", "coversBaseUrl": "\(covers)",
                     "reportUrl": "https://report.md.test/report", "trustedImageHost": "md.test",
                     "attribution": "Dados fornecidos pela fonte de teste."}
        }
        """
    }

    /// index.pb mínimo, gerado com o codificador protobuf do próprio projeto.
    static func protobuf(name: String = "Repo PB", extensions: Int = 2, listURL: String? = nil) -> Data {
        var w = ProtobufWriter()
        w.string(1, name)
        w.string(2, "PB")
        w.string(3, "abc")
        w.message(4) { $0.string(1, "https://pb.test") }
        if let listURL {
            w.string(102, listURL)
        } else {
            w.message(101) { list in
                for i in 0..<extensions { list.message(1) { extensionMessage(&$0, i) } }
            }
        }
        return w.data
    }

    static func extensionList(count: Int) -> Data {
        var w = ProtobufWriter()
        for i in 0..<count { w.message(1) { extensionMessage(&$0, i) } }
        return w.data
    }

    static func extensionMessage(_ e: inout ProtobufWriter, _ i: Int) {
        e.string(1, "Extensão \(i)")
        e.string(2, "eu.kanade.tachiyomi.extension.pt.ext\(i)")
        e.message(3) { $0.string(1, "https://pb.test/apk/\(i).apk"); $0.string(2, "https://pb.test/icon/\(i).png") }
        e.string(4, "1.4")
        e.varint(5, UInt64(10 + i))
        e.string(6, "1.4.\(i)")
        e.varint(7, 1)
        e.message(8) { s in s.int64(1, Int64(1000 + i)); s.string(2, "Fonte \(i)"); s.string(3, "pt-BR") }
    }
}

final class IndexFormatTests: XCTestCase {
    var cacheDir: URL!
    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-fmt-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cacheDir) }

    func client(_ http: StubHTTP, limits: CatalogLimits = CatalogLimits()) -> ExtensionCatalogClient {
        ExtensionCatalogClient(http: http, cacheDirectory: cacheDir, limits: limits)
    }

    /// Teste obrigatório 1 (parte JSON): index.json no formato JSON proto3.
    func testDecodesStoreJSONProto3() throws {
        let (format, data) = try ExtensionIndexDecoder.detect(Data(TestIndexes.storeJSON.utf8))
        XCTAssertEqual(format, .storeJSON)
        let index = try ExtensionIndexDecoder.decodeStoreJSON(data)
        XCTAssertEqual(index.name, "Repo de Teste")
        XCTAssertEqual(index.badgeLabel, "TST")
        XCTAssertEqual(index.discord, "https://chat.repo.test/convite")
        XCTAssertEqual(index.format, .storeJSON)
        XCTAssertEqual(index.extensions.count, 2)
        XCTAssertEqual(index.skippedEntries, 1, "entrada sem packageName é ignorada, sem derrubar a lista")
        let um = index.extensions[0]
        XCTAssertEqual(um.versionCode, 106_004, "int64 como texto")
        XCTAssertEqual(um.contentWarning, .nsfw, "enum pelo nome")
        XCTAssertEqual(um.sources[0].id, 6_289_731_484_943_315_811)
        XCTAssertEqual(um.jarURL, "https://repo.test/jar/um.jar")
        XCTAssertFalse(um.isNative)
        let dois = index.extensions[1]
        XCTAssertEqual(dois.contentWarning, .safe, "enum pelo número")
        XCTAssertEqual(dois.sources.map(\.id), [-7, 8])
        XCTAssertEqual(dois.languages, ["en", "es"])
    }

    func testIndexJSONThroughClient() async throws {
        let http = StubHTTP()
        http.responses["https://repo.test/index.json"] = .success(HTTPResponse(statusCode: 200, body: Data(TestIndexes.storeJSON.utf8)))
        let snap = try await client(http).fetch(from: "https://repo.test/index.json")
        XCTAssertEqual(snap.format, .storeJSON)
        XCTAssertEqual(snap.index.extensions.count, 2)
        XCTAssertEqual(http.requests.last?.timeout, CatalogLimits().timeout, "toda requisição tem tempo limite")
    }

    /// Teste obrigatório 1 (parte JSON): index.min.json legado + repo.json com metadados.
    func testLegacyIndexMinJSONUsesRepoJSONMeta() async throws {
        let http = StubHTTP()
        http.responses["https://legado.test/repo/index.min.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(TestIndexes.legacyList.utf8)))
        http.responses["https://legado.test/repo/repo.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(TestIndexes.legacyRepoMeta.utf8)))
        let snap = try await client(http).fetch(from: "https://legado.test/repo/index.min.json")
        XCTAssertEqual(snap.format, .legacyJSON)
        XCTAssertEqual(snap.index.name, "Repo Legado")
        XCTAssertEqual(snap.index.badgeLabel, "LEG")
        let antiga = try XCTUnwrap(snap.index.extensions.first)
        XCTAssertEqual(antiga.name, "Fonte Antiga", "prefixo \"Tachiyomi: \" removido")
        XCTAssertEqual(antiga.apkURL, "https://legado.test/repo/apk/tachiyomi-pt.antiga-v1.4.2.apk")
        XCTAssertEqual(antiga.iconURL, "https://legado.test/repo/icon/eu.kanade.tachiyomi.extension.pt.antiga.png")
        XCTAssertEqual(antiga.extensionLib, "1.4")
        XCTAssertEqual(antiga.versionCode, 2)
        XCTAssertEqual(antiga.sources.first?.id, 123)
        let adulta = snap.index.extensions[1]
        XCTAssertEqual(adulta.contentWarning, .nsfw)
        XCTAssertEqual(adulta.apkURL, "", "nome de arquivo com \"..\" não vira URL")
        XCTAssertEqual(adulta.sources.count, 1, "sem fontes: uma fonte com o nome da extensão")
    }

    func testLegacyIndexMinJSONWithoutRepoJSONStillWorks() async throws {
        let http = StubHTTP()
        http.responses["https://legado.test/x/index.min.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(TestIndexes.legacyList.utf8)))
        http.responses["https://legado.test/x/repo.json"] = .success(HTTPResponse(statusCode: 404, body: Data()))
        let snap = try await client(http).fetch(from: "https://legado.test/x/index.min.json")
        XCTAssertEqual(snap.index.name, "legado.test", "sem repo.json, o nome vem do endereço")
        XCTAssertEqual(snap.index.extensions.count, 2)
    }

    func testLegacyIndexMinJSONFollowsIndexV2() async throws {
        let http = StubHTTP()
        http.responses["https://novo.test/index.min.json"] = .success(HTTPResponse(statusCode: 200, body: Data("[]".utf8)))
        http.responses["https://novo.test/repo.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(#"{"index_v2":"index.pb","meta":{"name":"X","website":"","signingKeyFingerprint":""}}"#.utf8)))
        http.responses["https://novo.test/index.pb"] = .success(HTTPResponse(statusCode: 200, body: TestIndexes.protobuf()))
        let snap = try await client(http).fetch(from: "https://novo.test/index.min.json")
        XCTAssertEqual(snap.format, .protobuf, "como no Mihon, o repo.json leva ao índice novo")
        XCTAssertEqual(snap.sourceURL, "https://novo.test/index.pb")
        XCTAssertEqual(snap.index.extensions.count, 2)
    }

    func testRepoJSONWithMetaOnlyLoadsLegacyList() async throws {
        let http = StubHTTP()
        http.responses["https://legado.test/r/repo.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(TestIndexes.legacyRepoMeta.utf8)))
        http.responses["https://legado.test/r/index.min.json"] = .success(
            HTTPResponse(statusCode: 200, body: Data(TestIndexes.legacyList.utf8)))
        let snap = try await client(http).fetch(from: "https://legado.test/r/repo.json")
        XCTAssertEqual(snap.index.name, "Repo Legado")
        XCTAssertEqual(snap.index.extensions.count, 2)
    }

    /// Teste obrigatório 2 (núcleo): index.pb, inclusive com a lista em arquivo separado (campo 102).
    func testProtobufWithSeparateExtensionList() async throws {
        let http = StubHTTP()
        http.responses["https://pb.test/index.pb"] = .success(
            HTTPResponse(statusCode: 200, body: try Gzip.compress(TestIndexes.protobuf(listURL: "lista.pb"))))
        http.responses["https://pb.test/lista.pb"] = .success(
            HTTPResponse(statusCode: 200, body: TestIndexes.extensionList(count: 3)))
        let snap = try await client(http).fetch(from: "https://pb.test/index.pb")
        XCTAssertEqual(snap.format, .protobuf)
        XCTAssertEqual(snap.index.name, "Repo PB")
        XCTAssertEqual(snap.index.extensions.count, 3)
        XCTAssertEqual(snap.index.extensions[2].versionCode, 12)
    }

    func testFreeYomiNativeIndexResolvesRelativeURLs() throws {
        let data = Data(TestIndexes.freeyomi(sha256: String(repeating: "a", count: 64)).utf8)
        let (format, body) = try ExtensionIndexDecoder.detect(data)
        XCTAssertEqual(format, .freeyomi)
        let index = try ExtensionIndexDecoder.decodeFreeYomi(body, indexURL: URL(string: "https://nativo.test/repo/index.json")!)
        XCTAssertEqual(index.name, "Repo Nativo")
        XCTAssertEqual(index.extensions.count, 1)
        XCTAssertEqual(index.skippedEntries, 1, "id inválido é ignorado")
        let e = index.extensions[0]
        XCTAssertTrue(e.isNative)
        XCTAssertEqual(e.native?.manifestURL, "https://nativo.test/repo/extensoes/org.teste.md.json")
        XCTAssertEqual(e.iconURL, "https://nativo.test/repo/icones/md.png")
        XCTAssertEqual(e.native?.adapter, "mangadex-api-v5")
        XCTAssertEqual(e.contentWarning, .mixed)
        XCTAssertEqual(e.sources.first?.key, "pt-br")
    }

    /// Teste obrigatório 4: índices malformados são recusados com mensagem clara.
    func testMalformedIndexesAreRejected() async {
        let cases: [(String, Data)] = [
            ("JSON truncado", Data(#"{"name": "x", "extensionList": {"#.utf8)),
            ("lista truncada", Data("[{\"pkg\": ".utf8)),
            ("HTML", Data("<!doctype html><html></html>".utf8)),
            ("JSON sem nome", Data(#"{"extensionList": {"extensions": []}}"#.utf8)),
            ("protobuf corrompido", Data([0x0A, 0xFF, 0xFF, 0xFF, 0x7F])),
            ("vazio", Data()),
            ("FreeYomi futuro", Data(#"{"format": "freeyomi.repository.v9", "name": "x", "extensions": []}"#.utf8)),
            ("index.min.json sem extensões válidas", Data(#"[{"name": "sem pkg"}]"#.utf8)),
        ]
        for (label, body) in cases {
            let http = StubHTTP()
            http.responses["https://ruim.test/index.json"] = .success(HTTPResponse(statusCode: 200, body: body))
            http.responses["https://ruim.test/repo.json"] = .success(HTTPResponse(statusCode: 404, body: Data()))
            do {
                _ = try await client(http).fetch(from: "https://ruim.test/index.json")
                XCTFail("deveria recusar: \(label)")
            } catch {
                XCTAssertFalse(error.localizedDescription.isEmpty, label)
            }
        }
    }

    /// Teste obrigatório 13 (índice): arquivos grandes demais ou "gzip bomb".
    func testOversizedDownloadAndDecompressionBombAreRejected() async throws {
        var small = CatalogLimits()
        small.maxDownloadBytes = 1_000
        let http = StubHTTP()
        http.responses["https://grande.test/index.pb"] = .success(HTTPResponse(statusCode: 200, body: Data(count: 5_000)))
        do {
            _ = try await client(http, limits: small).fetch(from: "https://grande.test/index.pb")
            XCTFail("deveria recusar arquivo grande")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limite"), "\(error)")
        }

        var tight = CatalogLimits()
        tight.maxDecompressedBytes = 10_000
        let bomb = try Gzip.compress(Data(count: 2_000_000))
        let http2 = StubHTTP()
        http2.responses["https://bomba.test/index.pb"] = .success(HTTPResponse(statusCode: 200, body: bomb))
        do {
            _ = try await client(http2, limits: tight).fetch(from: "https://bomba.test/index.pb")
            XCTFail("deveria recusar gzip bomb")
        } catch {}
    }

    func testTooManyExtensionsRejected() async {
        var limits = CatalogLimits()
        limits.maxExtensions = 1
        let http = StubHTTP()
        http.responses["https://pb.test/index.pb"] = .success(HTTPResponse(statusCode: 200, body: TestIndexes.protobuf(extensions: 2)))
        do {
            _ = try await client(http, limits: limits).fetch(from: "https://pb.test/index.pb")
            XCTFail("deveria recusar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("mais de 1"))
        }
    }

    /// Teste obrigatório 6 (núcleo): falha de rede e tempo limite.
    func testNetworkFailureAndTimeoutAreReported() async {
        let http = StubHTTP()
        http.responses["https://lento.test/index.pb"] = .failure(FYError.network("tempo limite esgotado"))
        do {
            _ = try await client(http).refresh(from: "https://lento.test/index.pb")
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tempo limite"), "\(error)")
        }
    }

    /// Redirecionamento de HTTPS para HTTP é recusado, mesmo com HTTP permitido.
    func testRedirectDowngradeIsRejected() async {
        let http = StubHTTP()
        http.responses["https://redir.test/index.pb"] = .success(
            HTTPResponse(statusCode: 200, body: TestIndexes.protobuf(), finalURL: URL(string: "http://redir.test/index.pb")))
        for allow in [false, true] {
            do {
                _ = try await client(http).fetch(from: "https://redir.test/index.pb", allowHTTP: allow)
                XCTFail("deveria recusar o rebaixamento")
            } catch {
                guard case .insecureURL = error as? FYError else { return XCTFail("erro inesperado: \(error)") }
            }
        }
    }

    func testPlainHTTPRequiresExplicitPermission() async throws {
        let http = StubHTTP()
        http.responses["http://192.168.0.5/index.pb"] = .success(HTTPResponse(statusCode: 200, body: TestIndexes.protobuf()))
        do {
            _ = try await client(http).fetch(from: "http://192.168.0.5/index.pb")
            XCTFail("HTTP sem permissão deveria falhar")
        } catch {
            guard case .insecureURL = error as? FYError else { return XCTFail("erro inesperado: \(error)") }
        }
        let snap = try await client(http).fetch(from: "http://192.168.0.5/index.pb", allowHTTP: true)
        XCTAssertEqual(snap.index.name, "Repo PB")
    }

    /// Teste obrigatório 8 (núcleo): cache offline para todos os formatos.
    func testCacheKeepsJSONIndexesOffline() async throws {
        let http = StubHTTP()
        http.responses["https://repo.test/index.json"] = .success(HTTPResponse(statusCode: 200, body: Data(TestIndexes.storeJSON.utf8)))
        _ = try await client(http).refresh(from: "https://repo.test/index.json")
        let offline = try await client(StubHTTP()).refresh(from: "https://repo.test/index.json")
        XCTAssertTrue(offline.isFromCache)
        XCTAssertNotNil(offline.networkError)
        XCTAssertEqual(offline.format, .storeJSON)
        XCTAssertEqual(offline.index.extensions.count, 2)
    }

    func testFetchDoesNotWriteCache() async throws {
        let http = StubHTTP()
        http.responses["https://repo.test/index.json"] = .success(HTTPResponse(statusCode: 200, body: Data(TestIndexes.storeJSON.utf8)))
        _ = try await client(http).fetch(from: "https://repo.test/index.json")
        XCTAssertThrowsError(try client(http).loadCache(for: "https://repo.test/index.json"),
                             "validar não grava nada antes de o usuário confirmar")
    }
}
