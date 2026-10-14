import Foundation
import FYCore
import FYDomain

// MARK: - Extensões Android executadas pela JVM embutida
//
// Como o Tachimanga: o app traz uma máquina virtual Java (OpenJDK Mobile,
// interpretador Zero — sem JIT, sem gerar código nativo) e o runtime de
// compatibilidade do Tachidesk-Server. As extensões do formato Tachiyomi
// (o .jar publicado no campo `jarUrl` do índice, extensions-lib 1.3–1.6)
// rodam dentro dessa JVM, como bytecode interpretado.
//
// Este arquivo é a parte testável em qualquer plataforma: leitura do .jar,
// manifesto da instalação, instalação conferida e a fonte (`MangaSource`)
// que conversa com a JVM por mensagens JSON. A JVM em si (C/JNI) fica no app.
// Ver docs/EXTENSIONS_ARCHITECTURE.md.

/// Canal com a JVM embutida. O app implementa com a ponte JNI; os testes, com um dublê.
public protocol JVMBridge: Sendable {
    /// `false` quando o app foi compilado sem a JVM.
    var isAvailable: Bool { get }
    /// Envia um pedido `{"op": ...}` e devolve o campo `result` da resposta.
    func call(_ request: [String: Any]) async throws -> Any
}

/// Ponte de um app compilado sem a JVM.
public struct UnavailableJVMBridge: JVMBridge {
    public init() {}
    public var isAvailable: Bool { false }
    public func call(_ request: [String: Any]) async throws -> Any {
        throw FYError.unsupported("esta compilação do app não inclui o runtime de extensões")
    }
}

public enum JVMExtensionSupport {
    /// Nome do "adaptador" gravado em `installed_extensions.adapter`.
    public static let adapter = "jvm-tachiyomi"
    public static let adapterVersion = 1
    /// Versões da extensions-lib aceitas pelo runtime (as mesmas do Tachidesk-Server).
    public static let minLib = 1.3
    public static let maxLib = 1.6
    /// Limite do .jar baixado.
    public static let maxJarBytes = 30 * 1024 * 1024
    /// Prefixo dos IDs de fonte na biblioteca ("jvm:<id da fonte no Tachiyomi>").
    public static let sourcePrefix = "jvm:"

    /// Uma extensão Android pode rodar na JVM embutida?
    public static func check(_ ext: CatalogExtension) -> ExtensionCompatibility {
        guard ext.native == nil else { return .requiresAndroid }
        guard let jar = ext.jarURL, !jar.isEmpty else {
            return .unsupportedAdapter("o repositório publica só o APK desta extensão; o iOS precisa do .jar")
        }
        guard let lib = Double(ext.extensionLib), lib >= minLib, lib <= maxLib else {
            return .unsupportedAdapter("extensions-lib \(ext.extensionLib) não é suportada (aceitas: \(minLib)–\(maxLib))")
        }
        return .compatible(adapter: adapter)
    }

    public static func sourceID(_ tachiyomiID: String) -> SourceID {
        SourceID("\(sourcePrefix)\(tachiyomiID)")
    }
}

// MARK: - Leitura do .jar

public enum JVMJarInspector {
    public struct Info: Sendable, Equatable {
        public var packageName: String?
        /// Classe principal (`tachiyomi.extension.class`), já com o pacote.
        public var className: String
        public var nsfw: Bool
    }

    /// Lê o AndroidManifest.xml (texto) que as extensões do Keiyoushi trazem
    /// dentro do .jar e extrai a classe principal. Não carrega nada.
    public static func inspect(jarAt url: URL) throws -> Info {
        let zip: ZipArchive
        do {
            zip = try ZipArchive(url: url)
        } catch {
            throw FYError.invalidData("o arquivo baixado não é um .jar válido")
        }
        guard zip.entries.contains(where: { $0.rawPath.hasSuffix(".class") }) else {
            throw FYError.invalidData("o .jar não contém classes Java")
        }
        guard let entry = zip.entry(path: "AndroidManifest.xml") else {
            throw FYError.invalidData("o .jar não traz o AndroidManifest.xml da extensão")
        }
        guard entry.uncompressedSize <= 512 * 1024 else { throw FYError.invalidData("AndroidManifest.xml grande demais") }
        let data = try zip.data(for: entry)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FYError.invalidData("AndroidManifest.xml em formato binário (esperado texto)")
        }
        return try parseManifest(text)
    }

    public static func parseManifest(_ text: String) throws -> Info {
        let package = attribute("package", in: text)
        guard let raw = metaData("tachiyomi.extension.class", in: text)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            throw FYError.invalidData("o manifesto da extensão não informa a classe principal")
        }
        var className = raw
        if raw.hasPrefix(".") {
            guard let package else { throw FYError.invalidData("classe relativa sem pacote no manifesto") }
            className = package + raw
        }
        // Só nomes de classe Java (nada de caminhos ou caracteres estranhos).
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._$"))
        guard className.unicodeScalars.allSatisfy(allowed.contains), !className.contains("..") else {
            throw FYError.invalidData("nome de classe inválido no manifesto")
        }
        return Info(packageName: package, className: className, nsfw: metaData("tachiyomi.extension.nsfw", in: text) == "1")
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// `<meta-data android:name="X" android:value="Y"/>` (em qualquer ordem de atributos).
    private static func metaData(_ name: String, in text: String) -> String? {
        var search = text[...]
        while let start = search.range(of: "<meta-data") {
            let tail = search[start.upperBound...]
            guard let close = tail.firstIndex(of: ">") else { return nil }
            let tag = String(tail[..<close])
            if attribute("android:name", in: tag) == name { return attribute("android:value", in: tag) }
            search = tail[close...]
        }
        return nil
    }
}

// MARK: - Manifesto da instalação

/// Gravado em `installed_extensions.manifest` para extensões da JVM.
public struct JVMExtensionManifest: Codable, Sendable, Hashable {
    public static let format = "freeyomi.jvm-extension.v1"

    public struct Source: Codable, Sendable, Hashable {
        /// ID da fonte no Tachiyomi (Long, em texto).
        public var id: String
        public var name: String
        public var lang: String
        public var supportsLatest: Bool
        public var baseUrl: String
        /// Cabeçalhos HTTP da fonte (Referer, User-Agent…), usados para carregar imagens.
        public var headers: [String: String]
    }

    public var format: String
    public var packageName: String
    public var name: String
    public var versionCode: Int64
    public var versionName: String
    public var extensionLib: String
    /// Nome do arquivo na pasta de extensões (inclui a versão).
    public var jarFile: String
    public var jarSHA256: String
    public var className: String
    public var contentWarning: ContentWarning
    public var sources: [Source]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> JVMExtensionManifest {
        let m: JVMExtensionManifest
        do {
            m = try JSONDecoder().decode(JVMExtensionManifest.self, from: data)
        } catch {
            throw FYError.invalidData("registro da extensão corrompido; reinstale")
        }
        guard m.format == format else { throw FYError.unsupported("formato de registro \(m.format)") }
        guard m.jarFile.hasSuffix(".jar"), !m.jarFile.contains("/"), !m.jarFile.contains("\\"), !m.jarFile.hasPrefix(".") else { throw FYError.invalidData("nome de arquivo inválido") }
        return m
    }
}

// MARK: - Fonte

/// Fonte de uma extensão Tachiyomi executada pela JVM embutida.
public final class JVMExtensionSource: MangaSource, @unchecked Sendable {
    public let id: SourceID
    public let name: String
    public let language: String
    public let supportsLatest: Bool
    public let tachiyomiID: String
    public let imageHeaders: [String: String]
    public var kind: SourceKind { .online }
    public var supportsSearch: Bool { true }
    public var attribution: String? { "Extensão \(extensionName) executada no aparelho pelo runtime Java do app" }

    let extensionName: String
    let bridge: JVMBridge
    /// Carrega o .jar na JVM (uma vez) antes da primeira chamada.
    let prepare: @Sendable () async throws -> Void

    public init(source: JVMExtensionManifest.Source, extensionName: String, bridge: JVMBridge,
                prepare: @escaping @Sendable () async throws -> Void) {
        self.id = JVMExtensionSupport.sourceID(source.id)
        self.name = source.name
        self.language = source.lang
        self.supportsLatest = source.supportsLatest
        self.tachiyomiID = source.id
        self.extensionName = extensionName
        // Cabeçalhos que dependem da conexão não são repassados.
        let skip: Set<String> = ["host", "content-length", "connection", "accept-encoding", "cookie"]
        self.imageHeaders = source.headers.filter { !skip.contains($0.key.lowercased()) }
        self.bridge = bridge
        self.prepare = prepare
        SourceImageHeaders.shared.set(imageHeaders, for: id)
    }

    private func request(_ op: String, _ extra: [String: Any] = [:]) async throws -> Any {
        try await prepare()
        var body = extra
        body["op"] = op
        body["source"] = tachiyomiID
        return try await bridge.call(body)
    }

    public func popular(page: Int) async throws -> MangaListPage {
        try Self.listPage(try await request("popular", ["page": page]))
    }

    public func latest(page: Int) async throws -> MangaListPage {
        try Self.listPage(try await request(supportsLatest ? "latest" : "popular", ["page": page]))
    }

    public func search(query: String, page: Int) async throws -> MangaListPage {
        try Self.listPage(try await request("search", ["page": page, "query": query]))
    }

    public func details(for manga: SourceManga) async throws -> SourceManga {
        guard let object = try await request("details", ["manga": Self.mangaObject(manga)]) as? [String: Any],
              let result = Self.manga(object) else {
            throw FYError.invalidData("resposta inválida da extensão")
        }
        return result
    }

    public func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        guard let list = try await request("chapters", ["manga": Self.mangaObject(manga)]) as? [[String: Any]] else {
            throw FYError.invalidData("resposta inválida da extensão")
        }
        return list.compactMap { c in
            guard let url = c["url"] as? String, !url.isEmpty else { return nil }
            let date = JSONValue.double(c["dateUpload"]) ?? 0
            return SourceChapter(key: url, name: (c["name"] as? String) ?? url,
                                 number: JSONValue.double(c["number"]) ?? -1,
                                 scanlator: (c["scanlator"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 uploadDate: date > 0 ? Date(timeIntervalSince1970: Double(date) / 1000) : nil)
        }
    }

    public func pages(mangaKey: String, chapterKey: String) async throws -> [Page] {
        guard let list = try await request("pages", ["chapter": ["url": chapterKey]]) as? [[String: Any]] else {
            throw FYError.invalidData("resposta inválida da extensão")
        }
        var pages: [Page] = []
        for (position, p) in list.enumerated() {
            let image = (p["imageUrl"] as? String) ?? ""
            guard let url = URL(string: image), url.scheme == "https" || url.scheme == "http" else {
                throw FYError.unsupported("a extensão devolveu uma página que não é um endereço de imagem")
            }
            pages.append(Page(index: position, image: .remote(url: image, headers: imageHeaders)))
        }
        return pages
    }

    // MARK: Conversão

    static func listPage(_ value: Any) throws -> MangaListPage {
        guard let object = value as? [String: Any], let list = object["mangas"] as? [[String: Any]] else {
            throw FYError.invalidData("resposta inválida da extensão")
        }
        var seen = Set<String>()
        let items = list.compactMap(manga).filter { seen.insert($0.key).inserted }
        return MangaListPage(items: items, hasNextPage: JSONValue.bool(object["hasNextPage"]) ?? false)
    }

    static func manga(_ o: [String: Any]) -> SourceManga? {
        guard let url = o["url"] as? String, !url.isEmpty else { return nil }
        func text(_ key: String) -> String? {
            guard let s = o[key] as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let genres = (text("genre") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let status = PublicationStatus(rawValue: Int(JSONValue.double(o["status"]) ?? 0)) ?? .unknown
        return SourceManga(key: url, title: text("title") ?? url, author: text("author"), artist: text("artist"),
                           summary: text("description"), genres: genres, status: status, coverURL: text("thumbnailUrl"))
    }

    static func mangaObject(_ m: SourceManga) -> [String: Any] {
        var o: [String: Any] = ["url": m.key, "title": m.title, "status": m.status.rawValue]
        if let v = m.coverURL { o["thumbnailUrl"] = v }
        if let v = m.author { o["author"] = v }
        if let v = m.artist { o["artist"] = v }
        if let v = m.summary { o["description"] = v }
        if !m.genres.isEmpty { o["genre"] = m.genres.joined(separator: ", ") }
        return o
    }
}

/// Números e booleanos vindos do `JSONSerialization` (NSNumber no iOS) ou de dicionários Swift (testes).
enum JSONValue {
    static func double(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let i as Int64: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    static func bool(_ v: Any?) -> Bool? {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        default: return nil
        }
    }
}

/// Cabeçalhos que cada fonte exige para baixar imagens (capas incluídas).
/// Consultado pelo pipeline de imagens do app; nada é enviado a terceiros
/// além do que a própria fonte pede ao site dela.
public final class SourceImageHeaders: @unchecked Sendable {
    public static let shared = SourceImageHeaders()
    private var map: [SourceID: [String: String]] = [:]
    private let lock = NSLock()

    public func set(_ headers: [String: String], for id: SourceID) {
        lock.lock(); defer { lock.unlock() }
        map[id] = headers.isEmpty ? nil : headers
    }

    public func headers(for id: SourceID) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return map[id] ?? [:]
    }
}

// MARK: - Instalação

/// Baixa o .jar anunciado, confere e carrega na JVM antes de gravar.
/// Nada é marcado como instalado sem a JVM ter carregado a extensão e listado as fontes.
public struct JVMExtensionInstaller: Sendable {
    let catalog: ExtensionCatalogClient
    public let bridge: JVMBridge
    /// Pasta onde os .jar ficam (Application Support/FreeYomi/Extensions).
    public let directory: URL

    public init(catalog: ExtensionCatalogClient, bridge: JVMBridge, directory: URL) {
        self.catalog = catalog
        self.bridge = bridge
        self.directory = directory
    }

    public static func jarFileName(packageName: String, versionCode: Int64) -> String {
        let safe = packageName.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" ? String($0) : "_"
        }.joined()
        return "\(safe)-v\(versionCode).jar"
    }

    public func install(_ ext: CatalogExtension, allowHTTP: Bool) async throws -> JVMExtensionManifest {
        guard bridge.isAvailable else {
            throw FYError.unsupported("esta compilação do app não inclui o runtime de extensões")
        }
        if case .unsupportedAdapter(let message) = JVMExtensionSupport.check(ext) { throw FYError.unsupported(message) }
        guard let jarURL = ext.jarURL else { throw FYError.unsupported("extensão sem .jar") }
        let (data, _) = try await catalog.download(jarURL, allowHTTP: allowHTTP)
        guard data.count <= JVMExtensionSupport.maxJarBytes else { throw FYError.invalidData(".jar grande demais") }
        guard data.starts(with: [0x50, 0x4B, 0x03, 0x04]) else { throw FYError.invalidData("o arquivo baixado não é um .jar") }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = Self.jarFileName(packageName: ext.packageName, versionCode: ext.versionCode)
        let destination = directory.appendingPathComponent(fileName)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).jar")
        try data.write(to: temporary, options: .atomic)
        do {
            let info = try JVMJarInspector.inspect(jarAt: temporary)
            if let pkg = info.packageName, pkg != ext.packageName {
                throw FYError.invalidData("o .jar pertence a outra extensão (\(pkg))")
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            var manifest = JVMExtensionManifest(
                format: JVMExtensionManifest.format, packageName: ext.packageName, name: ext.name,
                versionCode: ext.versionCode, versionName: ext.versionName, extensionLib: ext.extensionLib,
                jarFile: fileName, jarSHA256: SHA256.hex(data), className: info.className,
                contentWarning: info.nsfw ? .nsfw : ext.contentWarning, sources: [])
            manifest.sources = try await load(manifest)
            guard !manifest.sources.isEmpty else { throw FYError.invalidData("a extensão não declarou nenhuma fonte") }
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Carrega o .jar na JVM e devolve as fontes que ele declara.
    public func load(_ manifest: JVMExtensionManifest) async throws -> [JVMExtensionManifest.Source] {
        let jar = directory.appendingPathComponent(manifest.jarFile)
        guard FileManager.default.fileExists(atPath: jar.path) else {
            throw FYError.notFound("o arquivo da extensão foi apagado; reinstale")
        }
        let result = try await bridge.call(["op": "load", "jar": jar.path, "className": manifest.className])
        guard let object = result as? [String: Any], let list = object["sources"] as? [[String: Any]] else {
            throw FYError.invalidData("resposta inválida do runtime de extensões")
        }
        return list.compactMap { s in
            guard let id = s["id"] as? String, let name = s["name"] as? String else { return nil }
            return JVMExtensionManifest.Source(id: id, name: name, lang: (s["lang"] as? String) ?? "all",
                                               supportsLatest: JSONValue.bool(s["supportsLatest"]) ?? false,
                                               baseUrl: (s["baseUrl"] as? String) ?? "",
                                               headers: (s["headers"] as? [String: String]) ?? [:])
        }
    }

    /// Confere se o .jar gravado é o mesmo que foi instalado.
    public func verifyStoredJar(_ manifest: JVMExtensionManifest) throws {
        let jar = directory.appendingPathComponent(manifest.jarFile)
        guard let data = try? Data(contentsOf: jar) else { throw FYError.notFound("o arquivo da extensão foi apagado; reinstale") }
        guard SHA256.hex(data) == manifest.jarSHA256 else {
            throw FYError.invalidData("o arquivo da extensão foi alterado; reinstale")
        }
    }

    public func removeJar(_ manifest: JVMExtensionManifest) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(manifest.jarFile))
    }
}

/// Carrega cada .jar na JVM uma única vez, sob demanda (a JVM só inicia
/// quando o usuário abre uma fonte dessas extensões).
public actor JVMExtensionLoader {
    public let installer: JVMExtensionInstaller
    private var loads: [String: Task<Void, Error>] = [:]

    public init(installer: JVMExtensionInstaller) {
        self.installer = installer
    }

    public func ensureLoaded(_ manifest: JVMExtensionManifest) async throws {
        if let task = loads[manifest.jarFile] { return try await task.value }
        let installer = installer
        let task = Task {
            try installer.verifyStoredJar(manifest)
            _ = try await installer.load(manifest)
        }
        loads[manifest.jarFile] = task
        do {
            try await task.value
        } catch {
            loads[manifest.jarFile] = nil
            throw error
        }
    }

    /// A instalação já carregou o .jar.
    public func markLoaded(_ manifest: JVMExtensionManifest) {
        loads[manifest.jarFile] = Task {}
    }
}
