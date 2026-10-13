import XCTest
@testable import FYSources
import FYCore
import FYDomain

final class NativeManifestTests: XCTestCase {
    func testParsesValidManifest() throws {
        let m = try NativeExtensionManifest.parse(Data(TestIndexes.manifest().utf8))
        XCTAssertEqual(m.id, "org.teste.md")
        XCTAssertEqual(m.versionCode, 1)
        XCTAssertEqual(m.adapter, "mangadex-api-v5")
        XCTAssertEqual(m.contentWarning, .mixed)
        XCTAssertEqual(m.sources.map(\.id), ["pt-br"])
        XCTAssertEqual(m.sourceID(m.sources[0]), "fyx:org.teste.md/pt-br")
        XCTAssertEqual(try m.requireHTTPS("apiBaseUrl"), "https://api.md.test")
    }

    func testRejectsInvalidManifests() {
        let base = TestIndexes.manifest()
        let cases: [(String, String)] = [
            ("formato futuro", base.replacingOccurrences(of: "freeyomi.extension.v1", with: "freeyomi.extension.v7")),
            ("id inválido", base.replacingOccurrences(of: "\"org.teste.md\"", with: "\"../etc\"")),
            ("sem fontes", base.replacingOccurrences(of: #"[{"id": "pt-br", "name": "Fonte MD", "language": "pt-br"}]"#, with: "[]")),
            ("fonte repetida", base.replacingOccurrences(
                of: #"[{"id": "pt-br", "name": "Fonte MD", "language": "pt-br"}]"#,
                with: #"[{"id": "a", "name": "A", "language": "en"}, {"id": "a", "name": "B", "language": "en"}]"#)),
            ("JSON quebrado", String(base.dropLast(5))),
        ]
        for (label, text) in cases {
            XCTAssertThrowsError(try NativeExtensionManifest.parse(Data(text.utf8)), label)
        }
        var huge = Data(TestIndexes.manifest().utf8)
        huge.append(Data(repeating: 0x20, count: NativeExtensionManifest.maxBytes))
        XCTAssertThrowsError(try NativeExtensionManifest.parse(huge)) {
            XCTAssertTrue($0.localizedDescription.contains("KB"))
        }
    }

    func testAdapterRequiresHTTPSConfiguration() throws {
        let insecure = try NativeExtensionManifest.parse(Data(TestIndexes.manifest(api: "http://api.md.test").utf8))
        XCTAssertThrowsError(try MangaDexAPIAdapter().validate(insecure))
        let ok = try NativeExtensionManifest.parse(Data(TestIndexes.manifest().utf8))
        let sources = try MangaDexAPIAdapter().makeSources(ok, context: AdapterContext(http: StubHTTP()))
        XCTAssertEqual(sources.map(\.id), ["fyx:org.teste.md/pt-br"])
        XCTAssertEqual(sources.first?.attribution, "Dados fornecidos pela fonte de teste.")
    }
}

final class CompatibilityTests: XCTestCase {
    func ext(native: NativeExtensionInfo?) -> CatalogExtension {
        CatalogExtension(name: "X", packageName: "org.teste.x", apkURL: native == nil ? "https://r/x.apk" : "", iconURL: "",
                         jarURL: nil, extensionLib: "1.4", versionCode: 1, versionName: "1", contentWarning: .safe,
                         sources: [], native: native)
    }

    /// Teste obrigatório 10: extensão Android é identificada como incompatível com iOS.
    func testAndroidExtensionIsIncompatible() throws {
        XCTAssertEqual(CompatibilityResolver.resolve(ext(native: nil)), .requiresAndroid)
        XCTAssertFalse(CompatibilityResolver.resolve(ext(native: nil)).isCompatible)
        let store = try ExtensionIndexDecoder.decodeStore(try ExtensionIndexDecoder.detect(try fixture()).1)
        XCTAssertTrue(store.extensions.allSatisfy { CompatibilityResolver.resolve($0) == .requiresAndroid },
                      "estar num repositório não torna uma extensão compatível")
    }

    func testNativeExtensionNeedsMatchingAdapterAndVersion() {
        let ok = NativeExtensionInfo(adapter: "mangadex-api-v5", adapterVersion: 1, manifestURL: "https://r/m.json", sha256: nil)
        XCTAssertEqual(CompatibilityResolver.resolve(ext(native: ok)), .compatible(adapter: "mangadex-api-v5"))
        var newer = ok
        newer.adapterVersion = 2
        guard case .unsupportedAdapter(let msg) = CompatibilityResolver.resolve(ext(native: newer)) else {
            return XCTFail("versão desconhecida deveria ser incompatível")
        }
        XCTAssertTrue(msg.contains("versão 2"))
        var unknown = ok
        unknown.adapter = "adaptador-inexistente"
        XCTAssertFalse(CompatibilityResolver.resolve(ext(native: unknown)).isCompatible)
        XCTAssertFalse(CompatibilityResolver.resolve(ext(native: ok), adapters: AdapterRegistry([])).isCompatible)
    }
}

final class InstallerVerificationTests: XCTestCase {
    var cacheDir: URL!
    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-inst-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cacheDir) }

    func entry(sha: String?, versionCode: Int64 = 1) -> CatalogExtension {
        CatalogExtension(name: "Fonte MD", packageName: "org.teste.md", apkURL: "", iconURL: "", jarURL: nil,
                         extensionLib: "mangadex-api-v5@1", versionCode: versionCode, versionName: "1.0.\(versionCode)",
                         contentWarning: .mixed, sources: [],
                         native: NativeExtensionInfo(adapter: "mangadex-api-v5", adapterVersion: 1,
                                                     manifestURL: "https://nativo.test/m.json", sha256: sha))
    }

    func testVerifiesHashVersionAndAdapter() async throws {
        let data = Data(TestIndexes.manifest().utf8)
        let http = StubHTTP()
        http.responses["https://nativo.test/m.json"] = .success(HTTPResponse(statusCode: 200, body: data))
        let installer = NativeExtensionInstaller(catalog: ExtensionCatalogClient(http: http, cacheDirectory: cacheDir))

        let pkg = try await installer.download(entry(sha: SHA256.hex(data)))
        XCTAssertTrue(pkg.integrityVerified)
        XCTAssertEqual(pkg.sha256, SHA256.hex(data))

        let unverified = try await installer.download(entry(sha: nil))
        XCTAssertFalse(unverified.integrityVerified, "sem hash publicado, a instalação é marcada como não conferida")

        // Teste obrigatório 13 (arquivo corrompido): hash diferente do publicado.
        do {
            _ = try await installer.download(entry(sha: String(repeating: "0", count: 64)))
            XCTFail("deveria recusar hash diferente")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256"))
        }
        // Versão anunciada diferente da do manifesto.
        do {
            _ = try await installer.download(entry(sha: nil, versionCode: 9))
            XCTFail("deveria recusar versão divergente")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("versão"))
        }
    }

    func testAndroidExtensionCannotBeInstalledOnDevice() async {
        let installer = NativeExtensionInstaller(catalog: ExtensionCatalogClient(http: StubHTTP(), cacheDirectory: cacheDir))
        let android = CatalogExtension(name: "A", packageName: "eu.kanade.tachiyomi.extension.pt.a", apkURL: "https://r/a.apk",
                                       iconURL: "", jarURL: nil, extensionLib: "1.4", versionCode: 1, versionName: "1",
                                       contentWarning: .safe, sources: [])
        do {
            _ = try await installer.download(android)
            XCTFail("APK nunca é instalado no iOS")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Android"))
        }
    }
}

final class ExtensionFileInspectorTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fy-insp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Teste obrigatório 10 (arquivo importado): um APK é reconhecido e recusado.
    func testRecognizesAndroidPackages() throws {
        var apk = ZipWriter()
        try apk.add(path: "AndroidManifest.xml", data: Data([0x03, 0x00, 0x08, 0x00]))
        try apk.add(path: "classes.dex", data: Data("dex\n035".utf8))
        let apkURL = try write("tachiyomi-pt.exemplo-v1.4.1.apk", apk.finish())
        XCTAssertEqual(ExtensionFileInspector.inspect(fileAt: apkURL), .androidPackage(kind: "APK"))

        var jar = ZipWriter()
        try jar.add(path: "META-INF/MANIFEST.MF", data: Data("Manifest-Version: 1.0\n".utf8))
        try jar.add(path: "eu/kanade/Exemplo.class", data: Data([0xCA, 0xFE, 0xBA, 0xBE]))
        let jarURL = try write("exemplo.jar", jar.finish())
        XCTAssertEqual(ExtensionFileInspector.inspect(fileAt: jarURL), .androidPackage(kind: "JAR"))
    }

    func testRecognizesNativeManifestAndRejectsOthers() throws {
        let data = Data(TestIndexes.manifest().utf8)
        let manifestURL = try write("org.teste.md.json", data)
        guard case .nativeManifest(let m, let bytes) = ExtensionFileInspector.inspect(fileAt: manifestURL) else {
            return XCTFail("manifesto não reconhecido")
        }
        XCTAssertEqual(m.id, "org.teste.md")
        XCTAssertEqual(bytes, data)

        let broken = try write("quebrado.json", Data(#"{"format": "freeyomi.extension.v1", "id": "x"}"#.utf8))
        guard case .invalidManifest = ExtensionFileInspector.inspect(fileAt: broken) else {
            return XCTFail("manifesto incompleto deveria ser inválido")
        }
        XCTAssertEqual(ExtensionFileInspector.inspect(fileAt: try write("foto.jpg", Data([0xFF, 0xD8, 0xFF, 0xE0]))), .unknown)
        XCTAssertEqual(ExtensionFileInspector.inspect(fileAt: try write("vazio.json", Data())), .unknown)
    }
}
