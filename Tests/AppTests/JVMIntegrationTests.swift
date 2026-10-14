import XCTest
@testable import FreeYomi
import FYCore
import FYData
import FYDomain
import FYServices
import FYSources

/// Serve o .jar de teste como se viesse de um repositório.
private final class FixtureHTTP: HTTPClient, @unchecked Sendable {
    let routes: [String: Data]
    init(_ routes: [String: Data]) { self.routes = routes }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let body = routes[request.url.absoluteString] else { throw FYError.notFound(request.url.absoluteString) }
        return HTTPResponse(statusCode: 200, body: body)
    }
}

/// Teste de ponta a ponta da JVM embutida no app real: instala uma extensão
/// Tachiyomi (.jar baixado pelo CI de um índice público) pelo mesmo caminho
/// da tela Extensões e navega por ela. Pulado quando o app foi compilado sem
/// a JVM ou sem a extensão de teste.
final class JVMIntegrationTests: XCTestCase {
    func fixture(_ name: String) -> URL? {
        Bundle(for: Self.self).resourceURL?.appendingPathComponent("Fixtures/\(name)")
    }

    func testInstallAndBrowseRealExtension() async throws {
        let jvm = EmbeddedJVM.shared
        try XCTSkipUnless(jvm.isAvailable, jvm.unavailableReason ?? "JVM indisponível")
        guard let jarURL = fixture("extension.jar"), let jar = try? Data(contentsOf: jarURL) else {
            throw XCTSkip("sem extensão de teste (Fixtures/extension.jar)")
        }
        let info = (try? String(contentsOf: fixture("extension.json")!, encoding: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        let package = info["packageName"] as? String ?? "eu.kanade.tachiyomi.extension.teste"
        let lib = info["extensionLib"] as? String ?? "1.5"

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-jvm-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let http = FixtureHTTP(["https://fixture.test/extension.jar": jar])
        let catalog = ExtensionCatalogClient(http: http, cacheDirectory: dir.appendingPathComponent("cache"))
        let registry = SourceRegistry.makeDefault()
        let manager = ExtensionManager(store: try DataStore.inMemory(), catalog: catalog, registry: registry,
                                       jvm: JVMExtensionInstaller(catalog: catalog, bridge: jvm,
                                                                  directory: dir.appendingPathComponent("Extensions")))
        let entry = CatalogExtension(name: info["name"] as? String ?? "Teste", packageName: package,
                                     apkURL: "", iconURL: "", jarURL: "https://fixture.test/extension.jar",
                                     extensionLib: lib, versionCode: 1, versionName: "\(lib).1",
                                     contentWarning: .safe, sources: [])

        let t0 = Date()
        let record = try await manager.install(entry, from: "https://fixture.test/index.json")
        let manifest = try JVMExtensionManifest.decode(record.manifest)
        let t1 = Date()
        print("FYJVM-APP instalar: \(manifest.name) — \(manifest.sources.count) fonte(s) em \(Int(t1.timeIntervalSince(t0) * 1000)) ms")
        let first = try XCTUnwrap(manifest.sources.first)
        let source = try XCTUnwrap(registry.source(JVMExtensionSupport.sourceID(first.id)))

        let popular = try await source.popular(page: 1)
        let t2 = Date()
        print("FYJVM-APP populares: \(popular.items.count) em \(Int(t2.timeIntervalSince(t1) * 1000)) ms — "
              + popular.items.prefix(3).map { "«\($0.title)»" }.joined(separator: " "))
        XCTAssertFalse(popular.items.isEmpty)

        // Detalhes, capítulos e páginas dependem do site estar no ar: registrados, sem falhar o teste.
        guard let manga = popular.items.first else { return }
        do {
            let details = try await source.details(for: manga)
            let chapters = try await source.chapters(for: details)
            let t3 = Date()
            print("FYJVM-APP detalhes+capítulos: \(chapters.count) capítulos em \(Int(t3.timeIntervalSince(t2) * 1000)) ms")
            if let chapter = chapters.first {
                let pages = try await source.pages(mangaKey: manga.key, chapterKey: chapter.key)
                print("FYJVM-APP páginas: \(pages.count) em \(Int(Date().timeIntervalSince(t3) * 1000)) ms — \(pages.first.map { "\($0.image)" } ?? "")")
            }
        } catch {
            print("FYJVM-APP aviso: \(error.localizedDescription)")
            let trace = (jvm.lastTrace ?? "").split(separator: "\n").prefix(12).joined(separator: " | ")
            print("FYJVM-APP pilha: \(trace)")
        }
    }
}
