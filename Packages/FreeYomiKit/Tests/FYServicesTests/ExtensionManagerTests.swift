import XCTest
@testable import FYServices
import FYData
import FYSources
import FYDomain
import FYCore

/// Cliente HTTP falso (respostas por URL exata), com troca de respostas entre etapas.
final class RouteHTTP: HTTPClient, @unchecked Sendable {
    private var routes: [String: Result<HTTPResponse, Error>] = [:]
    private var prefixRoutes: [(String, HTTPResponse)] = []
    private(set) var requested: [String] = []
    private let lock = NSLock()

    func set(_ url: String, _ body: String, status: Int = 200) { set(url, Data(body.utf8), status: status) }
    func set(_ url: String, _ body: Data, status: Int = 200) {
        lock.withLock { routes[url] = .success(HTTPResponse(statusCode: status, body: body)) }
    }
    func fail(_ url: String, _ error: Error) { lock.withLock { routes[url] = .failure(error) } }
    func prefix(_ p: String, _ body: String) {
        lock.withLock { prefixRoutes.append((p, HTTPResponse(statusCode: 200, body: Data(body.utf8)))) }
    }
    func clear() { lock.withLock { routes = [:]; prefixRoutes = [] } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = request.url.absoluteString
        let (exact, pre) = lock.withLock { () -> (Result<HTTPResponse, Error>?, HTTPResponse?) in
            requested.append(key)
            return (routes[key], prefixRoutes.first { key.hasPrefix($0.0) }?.1)
        }
        if let exact { return try exact.get() }
        if let pre { return pre }
        throw FYError.network("sem rota para \(key)")
    }
}

/// Repositórios e manifestos controlados pelos testes (nenhuma fonte real).
enum Fixtures {
    static let nativeIndexURL = "https://nativo.test/repo/index.json"
    static let manifestURL = "https://nativo.test/repo/org.teste.md.json"
    static let jsonIndexURL = "https://json.test/index.json"
    static let pbIndexURL = "https://pb.test/index.pb"

    static func manifest(versionCode: Int = 1) -> Data {
        Data("""
        {"format": "freeyomi.extension.v1", "id": "org.teste.md", "name": "Fonte MD",
         "versionCode": \(versionCode), "versionName": "1.0.\(versionCode)",
         "adapter": "mangadex-api-v5", "adapterVersion": 1, "contentWarning": "SAFE",
         "sources": [{"id": "pt-br", "name": "Fonte MD", "language": "pt-br"}],
         "config": {"apiBaseUrl": "https://api.md.test", "coversBaseUrl": "https://covers.md.test"}}
        """.utf8)
    }

    static func nativeIndex(versionCode: Int = 1, sha256: String?, name: String = "Repo Nativo") -> String {
        let hash = sha256.map { #""sha256": "\#($0)","# } ?? ""
        return """
        {"format": "freeyomi.repository.v1", "name": "\(name)", "badgeLabel": "NAT",
         "extensions": [{"id": "org.teste.md", "name": "Fonte MD", "versionCode": \(versionCode),
           "versionName": "1.0.\(versionCode)", "language": "pt-BR", "adapter": "mangadex-api-v5", "adapterVersion": 1,
           \(hash) "manifestUrl": "org.teste.md.json",
           "sources": [{"id": "pt-br", "name": "Fonte MD", "language": "pt-BR"}]}]}
        """
    }

    static let jsonIndex = """
    {"name": "Repo JSON", "badgeLabel": "JSN", "signingKey": "", "contact": {"website": "https://json.test"},
     "extensionList": {"extensions": [
       {"name": "Android Um", "packageName": "eu.kanade.tachiyomi.extension.pt.um",
        "resources": {"apkUrl": "https://json.test/um.apk", "iconUrl": ""}, "extensionLib": "1.4",
        "versionCode": "14", "versionName": "1.4.14", "contentWarning": "CONTENT_WARNING_SAFE",
        "sources": [{"id": "1", "name": "Android Um", "language": "pt-BR"}]}]}}
    """

    static func protobufIndex() -> Data {
        var w = ProtobufWriter()
        w.string(1, "Repo PB")
        w.string(2, "PB")
        w.message(4) { $0.string(1, "https://pb.test") }
        w.message(101) { list in
            list.message(1) { e in
                e.string(1, "Android PB")
                e.string(2, "eu.kanade.tachiyomi.extension.all.pb")
                e.message(3) { $0.string(1, "https://pb.test/pb.apk") }
                e.string(4, "1.4")
                e.varint(5, 7)
                e.string(6, "1.4.7")
                e.message(8) { s in s.int64(1, 99); s.string(2, "Android PB"); s.string(3, "en") }
            }
        }
        return w.data
    }

    static let mangaList = """
    {"result":"ok","data":[{"id":"obra-1","type":"manga",
      "attributes":{"title":{"pt-br":"Obra de Teste"},"description":{"pt-br":"Resumo"},"status":"ongoing","tags":[]},
      "relationships":[{"id":"cv","type":"cover_art","attributes":{"fileName":"capa.jpg"}}]}],
     "limit":30,"offset":0,"total":1}
    """
}

final class ExtensionManagerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-mgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeManager(_ http: HTTPClient, store: DataStore? = nil, registry: SourceRegistry = .makeDefault()) throws -> ExtensionManager {
        let catalog = ExtensionCatalogClient(http: http, cacheDirectory: dir.appendingPathComponent("cache"))
        return ExtensionManager(store: try store ?? DataStore.inMemory(), catalog: catalog, registry: registry)
    }

    func servingNativeRepo(_ http: RouteHTTP, versionCode: Int = 1, verified: Bool = true) {
        let manifest = Fixtures.manifest(versionCode: versionCode)
        http.set(Fixtures.manifestURL, manifest)
        http.set(Fixtures.nativeIndexURL, Fixtures.nativeIndex(versionCode: versionCode,
                                                              sha256: verified ? SHA256.hex(manifest) : nil))
    }

    // MARK: 14. Nada vem configurado

    /// Teste obrigatório 14: nenhum repositório, extensão ou fonte online vem por padrão.
    func testNothingIsPreconfigured() throws {
        let settings = AppSettings()
        XCTAssertTrue(settings.extensionRepositories.isEmpty)
        XCTAssertEqual(settings.catalogURL, "")
        XCTAssertFalse(settings.allowInsecureRepositoryHTTP, "HTTP desligado por padrão")

        let registry = SourceRegistry.makeDefault()
        let manager = try makeManager(RouteHTTP(), registry: registry)
        XCTAssertTrue(manager.repositories().isEmpty)
        XCTAssertTrue(manager.installedExtensions().isEmpty)
        XCTAssertTrue(manager.activateInstalledSources(context: AdapterContext(http: RouteHTTP())).isEmpty)
        XCTAssertFalse(registry.all.contains { $0.kind == .online }, "nenhuma fonte online registrada de fábrica")
        XCTAssertTrue(ExtensionListBuilder.build(catalogs: manager.cachedCatalogs(), repositories: [], installed: [],
                                                 adapters: manager.adapters, server: nil).isEmpty)
    }

    // MARK: 1 e 2. Adicionar repositórios válidos

    /// Teste obrigatório 1: adicionar um repositório JSON válido.
    func testAddValidJSONRepository() async throws {
        let http = RouteHTTP()
        http.set(Fixtures.jsonIndexURL, Fixtures.jsonIndex)
        let manager = try makeManager(http)

        let preview = try await manager.preview("json.test/index.json")
        XCTAssertEqual(preview.url, Fixtures.jsonIndexURL)
        XCTAssertEqual(preview.snapshot.format, .storeJSON)
        XCTAssertTrue(manager.repositories().isEmpty, "validar não salva nada")

        let record = try manager.add(preview)
        XCTAssertEqual(record.name, "Repo JSON")
        XCTAssertEqual(record.badgeLabel, "JSN")
        XCTAssertEqual(record.format, RepositoryIndexFormat.storeJSON.rawValue)
        XCTAssertEqual(record.extensionCount, 1)
        XCTAssertEqual(record.lastSyncSucceeded, true)
        XCTAssertEqual(manager.repositories().map(\.url), [Fixtures.jsonIndexURL])
        XCTAssertEqual(manager.cachedCatalogs().first?.snapshot?.index.extensions.count, 1, "índice salvo em cache")
    }

    /// Teste obrigatório 2: adicionar um repositório Protobuf válido.
    func testAddValidProtobufRepository() async throws {
        let http = RouteHTTP()
        http.set(Fixtures.pbIndexURL, try Gzip.compress(Fixtures.protobufIndex()))
        let manager = try makeManager(http)
        let record = try manager.add(try await manager.preview(Fixtures.pbIndexURL))
        XCTAssertEqual(record.name, "Repo PB")
        XCTAssertEqual(record.format, RepositoryIndexFormat.protobuf.rawValue)
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        XCTAssertEqual(ext.packageName, "eu.kanade.tachiyomi.extension.all.pb")
        XCTAssertEqual(ext.versionCode, 7)
    }

    // MARK: 3, 4, 5. Recusas

    /// Teste obrigatório 3: URL inválida é recusada antes de qualquer acesso à rede.
    func testRejectsInvalidURL() async throws {
        let http = RouteHTTP()
        let manager = try makeManager(http)
        for raw in ["", "javascript:alert(1)", "file:///etc/passwd", "data:application/json,{}", "https://exemplo.test",
                    "http://exemplo.test/index.json", "https://a:b@exemplo.test/index.json"] {
            do {
                _ = try await manager.preview(raw)
                XCTFail("deveria recusar \(raw)")
            } catch {
                XCTAssertTrue(error is RepositoryInputError, "\(raw): \(error)")
            }
        }
        XCTAssertTrue(http.requested.isEmpty, "nenhuma requisição para endereços recusados")
        XCTAssertTrue(manager.repositories().isEmpty)
    }

    /// Teste obrigatório 4: índice malformado não é salvo como se funcionasse.
    func testMalformedIndexIsNotSaved() async throws {
        let http = RouteHTTP()
        http.set("https://ruim.test/index.json", #"{"name": "Quebrado", "extensionList": {"extensions": ["#)
        let manager = try makeManager(http)
        do {
            _ = try await manager.preview("https://ruim.test/index.json")
            XCTFail("deveria recusar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("inválidos") || error.localizedDescription.contains("malformado"),
                          "\(error)")
        }
        XCTAssertTrue(manager.repositories().isEmpty)
    }

    /// Teste obrigatório 5: repositório duplicado (inclusive endereço equivalente).
    func testDuplicateRepositoryIsDetected() async throws {
        let http = RouteHTTP()
        let gh = "https://github.com/dono/repo/raw/main/index.json"
        http.set(gh, Fixtures.jsonIndex)
        let manager = try makeManager(http)
        let preview = try await manager.preview(gh)
        try manager.add(preview)
        for variant in [gh, "https://raw.githubusercontent.com/dono/repo/main/index.json",
                        "https://github.com/Dono/Repo/raw/refs/heads/main/index.json"] {
            do {
                _ = try await manager.preview(variant)
                XCTFail("deveria detectar duplicata: \(variant)")
            } catch {
                XCTAssertEqual(error as? RepositoryInputError, .alreadyAdded)
            }
        }
        XCTAssertThrowsError(try manager.add(preview), "gravar de novo também é recusado")
        XCTAssertEqual(manager.repositories().count, 1)
    }

    // MARK: 6, 7, 8. Rede, atualização e cache

    /// Teste obrigatório 6: falhas de rede e tempo limite são informadas e registradas.
    func testNetworkFailureAndTimeout() async throws {
        let http = RouteHTTP()
        http.fail("https://lento.test/index.json", FYError.network("tempo limite esgotado"))
        let manager = try makeManager(http)
        do {
            _ = try await manager.preview("https://lento.test/index.json")
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tempo limite"))
        }
        XCTAssertTrue(manager.repositories().isEmpty)

        // Repositório já cadastrado que deixa de responder: resultado registrado, sem derrubar nada.
        http.set(Fixtures.jsonIndexURL, Fixtures.jsonIndex)
        try manager.add(try await manager.preview(Fixtures.jsonIndexURL))
        http.fail(Fixtures.jsonIndexURL, FYError.network("tempo limite esgotado"))
        let result = await manager.refresh(Fixtures.jsonIndexURL)
        XCTAssertTrue(result.isUnavailable)
        XCTAssertNotNil(result.snapshot, "a cópia salva continua disponível")
        let record = try XCTUnwrap(manager.repositories().first)
        XCTAssertEqual(record.lastSyncSucceeded, false)
        XCTAssertTrue(record.lastSyncError?.contains("tempo limite") ?? false)
        XCTAssertEqual(record.name, "Repo JSON", "metadados anteriores preservados")
    }

    /// Teste obrigatório 7: atualizar metadados (nome, versão) e detectar atualização disponível.
    func testRefreshUpdatesMetadataAndOffersUpdate() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http, versionCode: 1)
        let manager = try makeManager(http)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        try await manager.install(ext, from: Fixtures.nativeIndexURL)

        let manifest2 = Fixtures.manifest(versionCode: 2)
        http.set(Fixtures.manifestURL, manifest2)
        http.set(Fixtures.nativeIndexURL, Fixtures.nativeIndex(versionCode: 2, sha256: SHA256.hex(manifest2), name: "Repo Renomeado"))
        let catalogs = await manager.refreshAll()
        let record = try XCTUnwrap(manager.repositories().first)
        XCTAssertEqual(record.name, "Repo Renomeado")
        XCTAssertEqual(record.lastSyncSucceeded, true)

        let rows = ExtensionListBuilder.build(catalogs: catalogs, repositories: manager.repositories(),
                                              installed: manager.installedExtensions(), adapters: manager.adapters, server: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].state, .updateAvailable(installedVersion: "1.0.1"))

        // Atualizar mantém a data de instalação e o ID das fontes (a biblioteca continua vinculada).
        let installedAt = try XCTUnwrap(manager.installedExtensions().first?.installedAt)
        let newer = try XCTUnwrap(catalogs.first?.snapshot?.index.extensions.first)
        try await manager.install(newer, from: Fixtures.nativeIndexURL)
        let updated = try XCTUnwrap(manager.installedExtensions().first)
        XCTAssertEqual(updated.versionCode, 2)
        XCTAssertEqual(updated.installedAt.timeIntervalSince1970, installedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    /// Teste obrigatório 8: sem rede, a lista continua visível a partir do cache.
    func testOfflineShowsCachedData() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        let store = try DataStore.inMemory()
        let online = try makeManager(http, store: store)
        try online.add(try await online.preview(Fixtures.nativeIndexURL))

        let offline = try makeManager(RouteHTTP(), store: store) // mesmo banco e cache, sem rede
        let cached = offline.cachedCatalogs()
        XCTAssertEqual(cached.first?.snapshot?.index.name, "Repo Nativo")
        let refreshed = await offline.refreshAll()
        XCTAssertTrue(refreshed[0].snapshot?.isFromCache ?? false)
        XCTAssertTrue(refreshed[0].isUnavailable, "a interface avisa que os dados podem estar desatualizados")
        let rows = ExtensionListBuilder.build(catalogs: refreshed, repositories: offline.repositories(), installed: [],
                                              adapters: offline.adapters, server: nil)
        XCTAssertEqual(rows.first?.state, .repositoryUnavailable)
    }

    // MARK: 9. Remover sem apagar a biblioteca

    /// Teste obrigatório 9: remover um repositório não apaga biblioteca, progresso nem extensões instaladas.
    func testRemovingRepositoryKeepsLibrary() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        let store = try DataStore.inMemory()
        let registry = SourceRegistry.makeDefault()
        let manager = try makeManager(http, store: store, registry: registry)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        try await manager.install(ext, from: Fixtures.nativeIndexURL)
        manager.activateInstalledSources(context: AdapterContext(http: http))

        let sourceID: SourceID = "fyx:org.teste.md/pt-br"
        let mangaId = try store.library.upsertManga(Manga(sourceId: sourceID, key: "obra-1", title: "Obra"))
        try store.library.add(mangaId: mangaId)
        let chapters = try store.chapters.upsert([Chapter(mangaId: mangaId, key: "c1", name: "Cap. 1", number: 1)], mangaId: mangaId)
        try store.chapters.setRead([chapters[0].id], read: true)

        let summary = try manager.remove(Fixtures.nativeIndexURL)
        XCTAssertEqual(summary.keptInstalledExtensions, ["Fonte MD"])
        XCTAssertTrue(manager.repositories().isEmpty)
        XCTAssertTrue(manager.cachedCatalogs().isEmpty)
        XCTAssertEqual(try store.library.items().count, 1, "biblioteca intacta")
        XCTAssertEqual(try store.chapters.chapters(mangaId: mangaId).first?.isRead, true, "progresso intacto")
        XCTAssertEqual(manager.installedExtensions().count, 1, "extensão continua instalada")
        XCTAssertNotNil(registry.source(sourceID), "a fonte continua funcionando")

        let rows = ExtensionListBuilder.build(catalogs: manager.cachedCatalogs(), repositories: manager.repositories(),
                                              installed: manager.installedExtensions(), adapters: manager.adapters, server: nil)
        XCTAssertEqual(rows.first?.origin, .removedRepository(url: Fixtures.nativeIndexURL), "origem informada claramente")
    }

    // MARK: 10. Android incompatível

    /// Teste obrigatório 10: extensões Android aparecem como incompatíveis no iPhone
    /// (e só como instaláveis no servidor do usuário, quando conectado).
    func testAndroidExtensionsAreIncompatibleOnDevice() async throws {
        let http = RouteHTTP()
        http.set(Fixtures.jsonIndexURL, Fixtures.jsonIndex)
        let manager = try makeManager(http)
        try manager.add(try await manager.preview(Fixtures.jsonIndexURL))
        let catalogs = manager.cachedCatalogs()

        let rows = ExtensionListBuilder.build(catalogs: catalogs, repositories: manager.repositories(), installed: [],
                                              adapters: manager.adapters, server: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].compatibility, .requiresAndroid)
        XCTAssertEqual(rows[0].runtime, .none)
        guard case .incompatible = rows[0].state else { return XCTFail("deveria ser incompatível: \(rows[0].state)") }

        let ext = try XCTUnwrap(catalogs.first?.snapshot?.index.extensions.first)
        do {
            try await manager.install(ext, from: Fixtures.jsonIndexURL)
            XCTFail("APK nunca é instalado no iPhone")
        } catch {}
        XCTAssertTrue(manager.installedExtensions().isEmpty, "nada foi marcado como instalado")

        let withServer = ExtensionListBuilder.build(
            catalogs: catalogs, repositories: manager.repositories(), installed: [], adapters: manager.adapters,
            server: ["eu.kanade.tachiyomi.extension.pt.um": ServerExtensionState(installed: true, hasUpdate: false, versionName: "1.4.14")])
        XCTAssertEqual(withServer[0].runtime, .server)
        XCTAssertEqual(withServer[0].state, .installed)
    }

    // MARK: 11. Instalação real de uma fonte compatível

    /// Teste obrigatório 11: instalar uma fonte compatível e usá-la de verdade
    /// (busca de títulos pelo adaptador, com a rede simulada).
    func testInstallsAndUsesCompatibleSource() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        http.prefix("https://api.md.test/manga?", Fixtures.mangaList)
        let registry = SourceRegistry.makeDefault()
        let manager = try makeManager(http, registry: registry)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        XCTAssertEqual(CompatibilityResolver.resolve(ext), .compatible(adapter: "mangadex-api-v5"))
        XCTAssertNil(registry.source("fyx:org.teste.md/pt-br"), "baixar o índice não instala nada")

        let record = try await manager.install(ext, from: Fixtures.nativeIndexURL)
        XCTAssertTrue(record.integrityVerified)
        XCTAssertEqual(record.repositoryURL, Fixtures.nativeIndexURL)
        XCTAssertTrue(manager.activateInstalledSources(context: AdapterContext(http: http)).isEmpty)

        let source = try XCTUnwrap(registry.source("fyx:org.teste.md/pt-br"))
        XCTAssertEqual(source.kind, .online)
        let page = try await source.search(query: "teste", page: 1)
        XCTAssertEqual(page.items.first?.title, "Obra de Teste")
        XCTAssertEqual(page.items.first?.coverURL, "https://covers.md.test/covers/obra-1/capa.jpg.256.jpg")

        let rows = ExtensionListBuilder.build(catalogs: manager.cachedCatalogs(), repositories: manager.repositories(),
                                              installed: manager.installedExtensions(), adapters: manager.adapters, server: nil)
        XCTAssertEqual(rows.first?.state, .installed)

        try manager.uninstall(record.id)
        XCTAssertNil(registry.source("fyx:org.teste.md/pt-br"))
        XCTAssertTrue(manager.installedExtensions().isEmpty)
    }

    func testDownloadInProgressAndFailureStates() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        let manager = try makeManager(http)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let catalogs = manager.cachedCatalogs()
        let downloading = ExtensionListBuilder.build(catalogs: catalogs, repositories: manager.repositories(), installed: [],
                                                     adapters: manager.adapters, server: nil, inProgress: ["org.teste.md"])
        XCTAssertEqual(downloading.first?.state, .downloading)
        let failed = ExtensionListBuilder.build(catalogs: catalogs, repositories: manager.repositories(), installed: [],
                                                adapters: manager.adapters, server: nil, failures: ["org.teste.md": "erro"])
        XCTAssertEqual(failed.first?.state, .failed("erro"))
        let noAdapter = ExtensionListBuilder.build(catalogs: catalogs, repositories: manager.repositories(), installed: [],
                                                   adapters: AdapterRegistry([]), server: nil)
        guard case .incompatible = noAdapter.first?.state else { return XCTFail("sem adaptador deveria ser incompatível") }
    }

    // MARK: 12. Persistência

    /// Teste obrigatório 12: repositórios e extensões sobrevivem ao reinício do app.
    func testDataSurvivesRestart() async throws {
        let dbURL = dir.appendingPathComponent("library.sqlite")
        let http = RouteHTTP()
        servingNativeRepo(http)
        do {
            let manager = try makeManager(http, store: try DataStore.open(fileURL: dbURL))
            try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
            let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
            try await manager.install(ext, from: Fixtures.nativeIndexURL)
        }
        let registry = SourceRegistry.makeDefault()
        let reopened = try makeManager(RouteHTTP(), store: try DataStore.open(fileURL: dbURL), registry: registry)
        XCTAssertEqual(reopened.repositories().map(\.url), [Fixtures.nativeIndexURL])
        XCTAssertEqual(reopened.repositories().first?.name, "Repo Nativo")
        XCTAssertNotNil(reopened.repositories().first?.lastSyncAt)
        XCTAssertEqual(reopened.installedExtensions().map(\.versionCode), [1])
        XCTAssertEqual(reopened.cachedCatalogs().first?.snapshot?.index.extensions.count, 1)
        XCTAssertTrue(reopened.activateInstalledSources(context: AdapterContext(http: RouteHTTP())).isEmpty,
                      "as fontes voltam sem acesso à rede")
        XCTAssertNotNil(registry.source("fyx:org.teste.md/pt-br"))
    }

    // MARK: 13. Arquivos grandes ou corrompidos

    /// Teste obrigatório 13: manifestos grandes demais ou adulterados não são instalados.
    func testOversizedOrCorruptedFilesAreRejected() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        let manager = try makeManager(http)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)

        var tampered = Fixtures.manifest()
        tampered.append(contentsOf: Array(" ".utf8)) // um byte a mais: o SHA-256 publicado não confere
        http.set(Fixtures.manifestURL, tampered)
        do {
            try await manager.install(ext, from: Fixtures.nativeIndexURL)
            XCTFail("manifesto adulterado não deveria ser instalado")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
        }

        var huge = Fixtures.manifest()
        huge.append(Data(repeating: 0x20, count: NativeExtensionManifest.maxBytes))
        XCTAssertThrowsError(try manager.installManifestFile(huge))
        XCTAssertThrowsError(try manager.installManifestFile(Data([0x00, 0xFF, 0x13])))
        XCTAssertTrue(manager.installedExtensions().isEmpty)
    }

    /// Falha de uma extensão não impede as outras de funcionar.
    func testActivationIsolatesFailures() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http)
        let store = try DataStore.inMemory()
        let registry = SourceRegistry.makeDefault()
        let manager = try makeManager(http, store: store, registry: registry)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        try await manager.install(ext, from: Fixtures.nativeIndexURL)

        // Uma segunda extensão, cujo manifesto foi alterado no banco depois da instalação.
        var broken = try XCTUnwrap(manager.installedExtensions().first)
        broken.id = "org.teste.quebrada"
        broken.name = "Quebrada"
        broken.manifest = Data("{}".utf8)
        try store.installedExtensions.upsert(broken)

        let failures = manager.activateInstalledSources(context: AdapterContext(http: http))
        XCTAssertEqual(Array(failures.keys), ["org.teste.quebrada"])
        XCTAssertNotNil(registry.source("fyx:org.teste.md/pt-br"), "a extensão íntegra continua ativa")
        XCTAssertNotNil(try store.installedExtensions.record(id: "org.teste.quebrada")?.lastError)
    }

    func testDowngradeIsRefused() async throws {
        let http = RouteHTTP()
        servingNativeRepo(http, versionCode: 2)
        let manager = try makeManager(http)
        try manager.add(try await manager.preview(Fixtures.nativeIndexURL))
        let v2 = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first)
        try await manager.install(v2, from: Fixtures.nativeIndexURL)
        XCTAssertThrowsError(try manager.installManifestFile(Fixtures.manifest(versionCode: 1)))
        XCTAssertEqual(manager.installedExtensions().first?.versionCode, 2)
    }

    // MARK: Migração da 0.3.x

    func testLegacyPreconfiguredRepositoryIsRemovedButUserChoicesAreKept() throws {
        let manager = try makeManager(RouteHTTP())
        var onlyDefault = AppSettings()
        onlyDefault.extensionRepositories = [ExtensionManager.legacyPreconfiguredRepository]
        let r1 = manager.migrateLegacySettings(&onlyDefault)
        XCTAssertTrue(r1.removedPreconfigured)
        XCTAssertTrue(r1.imported.isEmpty)
        XCTAssertTrue(onlyDefault.repositoriesMigrated)
        XCTAssertTrue(onlyDefault.extensionRepositories.isEmpty)
        XCTAssertTrue(manager.repositories().isEmpty)

        let manager2 = try makeManager(RouteHTTP())
        var chosen = AppSettings()
        chosen.extensionRepositories = ["https://meu.repo.test/index.min.json", ExtensionManager.legacyPreconfiguredRepository]
        let r2 = manager2.migrateLegacySettings(&chosen)
        XCTAssertFalse(r2.removedPreconfigured, "lista editada pelo usuário é mantida inteira")
        XCTAssertEqual(manager2.repositories().count, 2)
        let again = manager2.migrateLegacySettings(&chosen)
        XCTAssertEqual(again, RepositoryMigrationResult(), "roda uma única vez")
    }
}
