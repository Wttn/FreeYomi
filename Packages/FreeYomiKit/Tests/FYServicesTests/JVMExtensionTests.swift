import XCTest
@testable import FYServices
@testable import FYSources
import FYData
import FYDomain
import FYCore

/// Dublê da JVM embutida: responde por operação e registra os pedidos.
final class FakeJVM: JVMBridge, @unchecked Sendable {
    var isAvailable = true
    var responses: [String: Any] = [:]
    var failing: Set<String> = []
    private(set) var calls: [[String: Any]] = []
    private let lock = NSLock()

    var ops: [String] { lock.withLock { calls.compactMap { $0["op"] as? String } } }

    func call(_ request: [String: Any]) async throws -> Any {
        let op = request["op"] as? String ?? ""
        lock.withLock { calls.append(request) }
        if failing.contains(op) { throw FYError.invalidData("falha simulada em \(op)") }
        guard let r = responses[op] else { throw FYError.unsupported("sem resposta para \(op)") }
        return r
    }

    static func loadResponse(_ sources: [(String, String)] = [("123456789012345", "Fonte Java")]) -> [String: Any] {
        ["sources": sources.map { ["id": $0.0, "name": $0.1, "lang": "pt-BR", "supportsLatest": true,
                                   "baseUrl": "https://fonte.test",
                                   "headers": ["Referer": "https://fonte.test/", "User-Agent": "UA", "Cookie": "x"]] }]
    }
}

enum JVMFixtures {
    static let indexURL = "https://jvm.test/index.json"
    static let jarURL = "https://jvm.test/apk/teste.jar"
    static let package = "eu.kanade.tachiyomi.extension.pt.teste"

    static func manifestXML(className: String = ".Teste", nsfw: Bool = false) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="\(package)">
          <application android:label="Tachiyomi: Teste">
            <meta-data android:name="tachiyomi.extension.class" android:value="\(className)" />
            <meta-data android:value="\(nsfw ? 1 : 0)" android:name="tachiyomi.extension.nsfw" />
          </application>
        </manifest>
        """
    }

    static func jar(manifest: String? = manifestXML()) throws -> Data {
        var zip = ZipWriter()
        try zip.add(path: "META-INF/MANIFEST.MF", data: Data("Manifest-Version: 1.0\n".utf8))
        if let manifest { try zip.add(path: "AndroidManifest.xml", data: Data(manifest.utf8)) }
        try zip.add(path: "eu/kanade/tachiyomi/extension/pt/teste/Teste.class", data: Data([0xCA, 0xFE, 0xBA, 0xBE]))
        return zip.finish()
    }

    /// Índice (formato JSON do Mihon) com uma extensão que publica .jar e outra só com APK.
    static func index(versionCode: Int = 3, lib: String = "1.5") -> String {
        """
        {"name": "Repo Java", "badgeLabel": "JVM", "signingKey": "",
         "extensionList": {"extensions": [
           {"name": "Teste", "packageName": "\(package)",
            "resources": {"apkUrl": "https://jvm.test/apk/teste.apk", "iconUrl": "", "jarUrl": "\(jarURL)"},
            "extensionLib": "\(lib)", "versionCode": "\(versionCode)", "versionName": "\(lib).\(versionCode)",
            "contentWarning": "CONTENT_WARNING_SAFE",
            "sources": [{"id": "123456789012345", "name": "Teste", "language": "pt-BR"}]},
           {"name": "Só APK", "packageName": "eu.kanade.tachiyomi.extension.pt.soapk",
            "resources": {"apkUrl": "https://jvm.test/apk/soapk.apk", "iconUrl": ""},
            "extensionLib": "1.5", "versionCode": "1", "versionName": "1.5.1", "contentWarning": "CONTENT_WARNING_SAFE",
            "sources": [{"id": "2", "name": "Só APK", "language": "pt-BR"}]}]}}
        """
    }

    static func catalogEntry(jar: String? = jarURL, lib: String = "1.5", versionCode: Int64 = 3) -> CatalogExtension {
        CatalogExtension(name: "Teste", packageName: package, apkURL: "https://jvm.test/apk/teste.apk", iconURL: "",
                         jarURL: jar, extensionLib: lib, versionCode: versionCode, versionName: "\(lib).\(versionCode)",
                         contentWarning: .safe, sources: [])
    }
}

final class JVMJarInspectorTests: XCTestCase {
    func testReadsMainClassFromTextManifest() throws {
        let relative = try JVMJarInspector.parseManifest(JVMFixtures.manifestXML())
        XCTAssertEqual(relative.className, "\(JVMFixtures.package).Teste")
        XCTAssertEqual(relative.packageName, JVMFixtures.package)
        XCTAssertFalse(relative.nsfw)

        let absolute = try JVMJarInspector.parseManifest(JVMFixtures.manifestXML(className: "keiyoushi.source.Generated", nsfw: true))
        XCTAssertEqual(absolute.className, "keiyoushi.source.Generated")
        XCTAssertTrue(absolute.nsfw, "atributos em qualquer ordem")
    }

    func testRejectsBadManifests() {
        XCTAssertThrowsError(try JVMJarInspector.parseManifest("<manifest package=\"a.b\"></manifest>"))
        XCTAssertThrowsError(try JVMJarInspector.parseManifest(JVMFixtures.manifestXML(className: "../../etc/passwd")))
        XCTAssertThrowsError(try JVMJarInspector.parseManifest(JVMFixtures.manifestXML(className: "a b;rm")))
    }

    func testInspectsJarFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-jar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.jar")
        try JVMFixtures.jar().write(to: good)
        XCTAssertEqual(try JVMJarInspector.inspect(jarAt: good).className, "\(JVMFixtures.package).Teste")

        let noManifest = dir.appendingPathComponent("b.jar")
        try JVMFixtures.jar(manifest: nil).write(to: noManifest)
        XCTAssertThrowsError(try JVMJarInspector.inspect(jarAt: noManifest))

        let notZip = dir.appendingPathComponent("c.jar")
        try Data("não é zip".utf8).write(to: notZip)
        XCTAssertThrowsError(try JVMJarInspector.inspect(jarAt: notZip))
    }
}

final class JVMCompatibilityTests: XCTestCase {
    func testJarAndLibVersionDecideCompatibility() {
        XCTAssertEqual(JVMExtensionSupport.check(JVMFixtures.catalogEntry()), .compatible(adapter: JVMExtensionSupport.adapter))
        XCTAssertFalse(JVMExtensionSupport.check(JVMFixtures.catalogEntry(jar: nil)).isCompatible, "só APK: sem .jar")
        XCTAssertFalse(JVMExtensionSupport.check(JVMFixtures.catalogEntry(lib: "1.2")).isCompatible)
        XCTAssertFalse(JVMExtensionSupport.check(JVMFixtures.catalogEntry(lib: "1.7")).isCompatible)
        // Sem a JVM, extensão Android continua incompatível (comportamento anterior preservado).
        XCTAssertEqual(CompatibilityResolver.resolve(JVMFixtures.catalogEntry()), .requiresAndroid)
    }

    func testListingUsesJVMOnlyWhenAvailable() throws {
        var soAPK = JVMFixtures.catalogEntry(jar: nil)
        soAPK.packageName = "eu.kanade.tachiyomi.extension.pt.soapk"
        let index = ExtensionStoreIndex(name: "Repo Java", badgeLabel: "JVM", signingKey: "", website: "", discord: nil,
                                        extensions: [JVMFixtures.catalogEntry(), soAPK], extensionListURL: nil,
                                        format: .storeJSON, skippedEntries: 0)
        let snap = CatalogSnapshot(index: index, sourceURL: JVMFixtures.indexURL, fetchedAt: Date(), isFromCache: false,
                                   networkError: nil)
        let catalogs = [RepositoryCatalog(indexURL: JVMFixtures.indexURL, snapshot: snap, error: nil)]
        let without = ExtensionListBuilder.build(catalogs: catalogs, repositories: [], installed: [], adapters: .builtIn, server: nil)
        XCTAssertTrue(without.allSatisfy { if case .incompatible = $0.state { return true }; return false })

        let with = ExtensionListBuilder.build(catalogs: catalogs, repositories: [], installed: [], adapters: .builtIn,
                                              server: nil, jvmAvailable: true)
        let jar = try XCTUnwrap(with.first { $0.packageName == JVMFixtures.package })
        XCTAssertEqual(jar.state, .available)
        XCTAssertEqual(jar.runtime, .device)
        XCTAssertEqual(jar.catalogEntry?.jarURL, JVMFixtures.jarURL)
        let apkOnly = try XCTUnwrap(with.first { $0.packageName.hasSuffix("soapk") })
        guard case .incompatible = apkOnly.state else { return XCTFail("sem .jar não roda no aparelho") }

        // Com servidor conectado, a extensão sem .jar continua podendo ir para o servidor.
        let withServer = ExtensionListBuilder.build(catalogs: catalogs, repositories: [], installed: [], adapters: .builtIn,
                                                    server: [:], jvmAvailable: true)
        XCTAssertEqual(withServer.first { $0.packageName.hasSuffix("soapk") }?.runtime, .server)
        XCTAssertEqual(withServer.first { $0.packageName == JVMFixtures.package }?.runtime, .device)
    }
}

final class JVMExtensionManagerTests: XCTestCase {
    var dir: URL!
    var jarsDir: URL { dir.appendingPathComponent("Extensions") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-jvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func make(_ http: RouteHTTP, jvm: FakeJVM, store: DataStore? = nil,
              registry: SourceRegistry = .makeDefault()) throws -> ExtensionManager {
        let catalog = ExtensionCatalogClient(http: http, cacheDirectory: dir.appendingPathComponent("cache"))
        return ExtensionManager(store: try store ?? DataStore.inMemory(), catalog: catalog, registry: registry,
                                jvm: JVMExtensionInstaller(catalog: catalog, bridge: jvm, directory: jarsDir))
    }

    func serving(_ http: RouteHTTP, versionCode: Int = 3) throws {
        http.set(JVMFixtures.indexURL, JVMFixtures.index(versionCode: versionCode))
        http.set(JVMFixtures.jarURL, try JVMFixtures.jar())
    }

    func testInstallsLoadsAndRegistersSources() async throws {
        let http = RouteHTTP()
        try serving(http)
        let jvm = FakeJVM()
        jvm.responses["load"] = FakeJVM.loadResponse()
        let registry = SourceRegistry.makeDefault()
        let manager = try make(http, jvm: jvm, registry: registry)
        try manager.add(try await manager.preview(JVMFixtures.indexURL))
        let ext = try XCTUnwrap(manager.cachedCatalogs().first?.snapshot?.index.extensions.first { $0.packageName == JVMFixtures.package })

        let record = try await manager.install(ext, from: JVMFixtures.indexURL)
        XCTAssertEqual(record.adapter, JVMExtensionSupport.adapter)
        XCTAssertFalse(record.integrityVerified, "o índice não publica hash do .jar")
        let manifest = try JVMExtensionManifest.decode(record.manifest)
        XCTAssertEqual(manifest.className, "\(JVMFixtures.package).Teste")
        XCTAssertEqual(manifest.sources.map(\.id), ["123456789012345"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: jarsDir.appendingPathComponent(manifest.jarFile).path))
        XCTAssertEqual(jvm.ops, ["load"], "a instalação só termina depois de a JVM carregar a extensão")
        XCTAssertEqual(jvm.calls.first?["className"] as? String, manifest.className)

        let source = try XCTUnwrap(registry.source("jvm:123456789012345") as? JVMExtensionSource)
        XCTAssertEqual(source.name, "Fonte Java")
        XCTAssertEqual(source.imageHeaders["Referer"], "https://fonte.test/")
        XCTAssertNil(source.imageHeaders["Cookie"], "cabeçalhos de conexão/cookies não são repassados")

        let rows = ExtensionListBuilder.build(catalogs: manager.cachedCatalogs(), repositories: manager.repositories(),
                                              installed: manager.installedExtensions(), adapters: manager.adapters,
                                              server: nil, jvmAvailable: true)
        XCTAssertEqual(rows.first { $0.packageName == JVMFixtures.package }?.state, .installed)

        // Desinstalar apaga o .jar e retira as fontes; a biblioteca não é tocada.
        try manager.uninstall(JVMFixtures.package)
        XCTAssertNil(registry.source("jvm:123456789012345"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jarsDir.appendingPathComponent(manifest.jarFile).path))
        XCTAssertTrue(manager.installedExtensions().isEmpty)
    }

    /// Nunca simular instalação: se a JVM não carrega a extensão, nada é gravado.
    func testFailedLoadInstallsNothing() async throws {
        let http = RouteHTTP()
        try serving(http)
        let jvm = FakeJVM()
        jvm.failing = ["load"]
        let manager = try make(http, jvm: jvm)
        do {
            _ = try await manager.install(JVMFixtures.catalogEntry(), from: JVMFixtures.indexURL)
            XCTFail("deveria falhar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("falha simulada"))
        }
        XCTAssertTrue(manager.installedExtensions().isEmpty)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: jarsDir.path))?.count ?? 0, 0, "nenhum .jar sobra")
    }

    func testCorruptedJarIsRejected() async throws {
        let http = RouteHTTP()
        http.set(JVMFixtures.jarURL, Data("<html>não é um jar</html>".utf8))
        let jvm = FakeJVM()
        let manager = try make(http, jvm: jvm)
        do {
            _ = try await manager.install(JVMFixtures.catalogEntry(), from: JVMFixtures.indexURL)
            XCTFail("deveria recusar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("jar"))
        }
        XCTAssertTrue(jvm.ops.isEmpty, "nada chega à JVM")
    }

    func testWithoutRuntimeAndroidExtensionsCannotInstall() async throws {
        let http = RouteHTTP()
        try serving(http)
        let jvm = FakeJVM()
        jvm.isAvailable = false
        let manager = try make(http, jvm: jvm)
        XCTAssertFalse(manager.jvmAvailable)
        do {
            _ = try await manager.install(JVMFixtures.catalogEntry(), from: JVMFixtures.indexURL)
            XCTFail("sem runtime não instala")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("runtime"))
        }
        XCTAssertTrue(http.requested.isEmpty)
    }

    /// Reabrir o app registra as fontes sem iniciar a JVM; ela só carrega o .jar no primeiro uso.
    func testActivationIsLazyAndUpdateReplacesJar() async throws {
        let http = RouteHTTP()
        try serving(http)
        let store = try DataStore.inMemory()
        let jvm = FakeJVM()
        jvm.responses["load"] = FakeJVM.loadResponse()
        let first = try make(http, jvm: jvm, store: store)
        let oldManifest = try JVMExtensionManifest.decode(try await first.install(JVMFixtures.catalogEntry(), from: JVMFixtures.indexURL).manifest)

        let jvm2 = FakeJVM()
        jvm2.responses["load"] = FakeJVM.loadResponse()
        jvm2.responses["popular"] = ["mangas": [["url": "/obra/1", "title": "Obra Um", "thumbnailUrl": "https://fonte.test/c.jpg",
                                                 "genre": "Ação, Drama", "status": 1],
                                                ["url": "/obra/1", "title": "Repetida"], ["title": "sem url"]],
                                     "hasNextPage": true]
        let registry = SourceRegistry.makeDefault()
        let second = try make(http, jvm: jvm2, store: store, registry: registry)
        XCTAssertTrue(second.activateInstalledSources(context: AdapterContext()).isEmpty)
        XCTAssertTrue(jvm2.ops.isEmpty, "ativar não inicia a JVM")
        let source = try XCTUnwrap(registry.source("jvm:123456789012345"))
        let page = try await source.popular(page: 1)
        XCTAssertEqual(jvm2.ops, ["load", "popular"])
        XCTAssertEqual(page.items.map(\.title), ["Obra Um"], "sem duplicatas nem itens sem endereço")
        XCTAssertEqual(page.items.first?.genres, ["Ação", "Drama"])
        XCTAssertEqual(page.items.first?.status, .ongoing)
        XCTAssertTrue(page.hasNextPage)
        _ = try await source.popular(page: 2)
        XCTAssertEqual(jvm2.ops.filter { $0 == "load" }.count, 1, "o .jar é carregado uma vez só")

        // Atualização: novo .jar, o antigo é apagado.
        http.set(JVMFixtures.jarURL, try JVMFixtures.jar())
        let updated = try await second.install(JVMFixtures.catalogEntry(versionCode: 4), from: JVMFixtures.indexURL)
        let newManifest = try JVMExtensionManifest.decode(updated.manifest)
        XCTAssertNotEqual(newManifest.jarFile, oldManifest.jarFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: jarsDir.appendingPathComponent(oldManifest.jarFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jarsDir.appendingPathComponent(newManifest.jarFile).path))

        // .jar adulterado no disco: a fonte recusa carregar.
        try Data("adulterado".utf8).write(to: jarsDir.appendingPathComponent(newManifest.jarFile))
        let jvm3 = FakeJVM()
        jvm3.responses["load"] = FakeJVM.loadResponse()
        let registry3 = SourceRegistry.makeDefault()
        let third = try make(http, jvm: jvm3, store: store, registry: registry3)
        third.activateInstalledSources(context: AdapterContext())
        do {
            _ = try await XCTUnwrap(registry3.source("jvm:123456789012345")).popular(page: 1)
            XCTFail("deveria recusar o .jar alterado")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("alterado"))
        }
        XCTAssertTrue(jvm3.ops.isEmpty)
    }

    func testSourceConvertsChaptersAndPages() async throws {
        let jvm = FakeJVM()
        jvm.responses["chapters"] = [["url": "/c/2", "name": "Capítulo 2", "number": 2.0, "scanlator": "",
                                      "dateUpload": 1_700_000_000_000],
                                     ["url": "/c/1", "name": "Capítulo 1", "number": 1.0, "dateUpload": 0]]
        jvm.responses["pages"] = [["index": 0, "url": "", "imageUrl": "https://img.test/1.jpg"],
                                  ["index": 1, "url": "", "imageUrl": "https://img.test/2.jpg"]]
        let source = JVMExtensionSource(
            source: .init(id: "77", name: "F", lang: "pt-BR", supportsLatest: false, baseUrl: "https://f.test",
                          headers: ["Referer": "https://f.test/"]),
            extensionName: "Ext", bridge: jvm, prepare: {})
        let chapters = try await source.chapters(for: SourceManga(key: "/obra", title: "Obra"))
        XCTAssertEqual(chapters.map(\.key), ["/c/2", "/c/1"])
        XCTAssertNil(chapters[0].scanlator)
        XCTAssertEqual(chapters[0].uploadDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(chapters[1].uploadDate)
        XCTAssertEqual((jvm.calls.last?["manga"] as? [String: Any])?["url"] as? String, "/obra")

        let pages = try await source.pages(mangaKey: "/obra", chapterKey: "/c/1")
        XCTAssertEqual(pages.map(\.index), [0, 1])
        XCTAssertEqual(pages[0].image, .remote(url: "https://img.test/1.jpg", headers: ["Referer": "https://f.test/"]))
        XCTAssertEqual(SourceImageHeaders.shared.headers(for: "jvm:77")["Referer"], "https://f.test/")

        jvm.responses["pages"] = [["index": 0, "url": "", "imageUrl": "javascript:alert(1)"]]
        do {
            _ = try await source.pages(mangaKey: "/obra", chapterKey: "/c/1")
            XCTFail("endereço que não é imagem")
        } catch {}
    }
}
