import Foundation
import FYCore
import FYDomain

// MARK: - Extensões nativas do FreeYomi
//
// O iOS não executa extensões Android (APK/JAR com código Kotlin), e o
// FreeYomi não baixa nem executa código de terceiros. Uma extensão nativa é
// um MANIFESTO DECLARATIVO (JSON, só dados) que um repositório publica e que
// é interpretado por um ADAPTADOR Swift já compilado no app e revisado no
// repositório do FreeYomi. Instalar = baixar o manifesto, conferir tamanho,
// SHA-256, formato, versão e configuração, e só então ativar as fontes.
// Sem o adaptador correspondente, a extensão aparece como incompatível.
// Ver docs/EXTENSIONS_ARCHITECTURE.md.

/// Manifesto `freeyomi.extension.v1`.
public struct NativeExtensionManifest: Sendable, Hashable {
    public static let supportedFormats: Set<String> = ["freeyomi.extension.v1"]
    /// Um manifesto é só configuração: qualquer coisa maior é recusada.
    public static let maxBytes = 256 * 1024
    /// Prefixo dos IDs de fonte das extensões nativas na biblioteca.
    public static let sourcePrefix = "fyx:"

    public struct Source: Sendable, Hashable {
        public var id: String
        public var name: String
        public var language: String
        public var homeURL: String?
    }

    public var format: String
    public var id: String
    public var name: String
    public var versionCode: Int64
    public var versionName: String
    public var adapter: String
    public var adapterVersion: Int
    public var contentWarning: ContentWarning
    public var sources: [Source]
    /// Configuração interpretada pelo adaptador (ex.: endereços da API).
    public var config: [String: String]

    /// ID estável da fonte na biblioteca: não muda entre versões da extensão,
    /// por isso atualizar não desvincula os títulos salvos.
    public func sourceID(_ source: Source) -> SourceID {
        SourceID("\(Self.sourcePrefix)\(id)/\(source.id)")
    }

    // MARK: Leitura e validação

    private struct JSONForm: Decodable {
        let format: String
        let id: String
        let name: String
        let versionCode: ExtensionIndexDecoder.FlexInt64
        let versionName: String?
        let adapter: String
        let adapterVersion: Int
        let contentWarning: ExtensionIndexDecoder.FlexWarning?
        let sources: [SourceJSON]
        let config: [String: String]?

        struct SourceJSON: Decodable {
            let id: String
            let name: String
            let language: String
            let homeUrl: String?
        }
    }

    /// Lê e valida um manifesto. Nunca executa nada: só interpreta dados.
    public static func parse(_ data: Data) throws -> NativeExtensionManifest {
        guard data.count <= maxBytes else {
            throw FYError.invalidData("manifesto maior que \(maxBytes / 1024) KB")
        }
        let json: JSONForm
        do {
            json = try JSONDecoder().decode(JSONForm.self, from: data)
        } catch {
            throw FYError.invalidData("manifesto de extensão malformado ou incompleto")
        }
        guard supportedFormats.contains(json.format) else {
            throw FYError.unsupported("manifesto no formato \(json.format), que esta versão do app não conhece")
        }
        guard isValidID(json.id) else { throw FYError.invalidData("identificador de extensão inválido") }
        let name = json.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw FYError.invalidData("nome de extensão inválido") }
        guard json.versionCode.value >= 0 else { throw FYError.invalidData("versionCode negativo") }
        guard !json.adapter.isEmpty, json.adapter.count <= 64, json.adapterVersion > 0 else {
            throw FYError.invalidData("adaptador não informado")
        }
        guard (1...50).contains(json.sources.count) else {
            throw FYError.invalidData("o manifesto precisa declarar entre 1 e 50 fontes")
        }
        var keys = Set<String>()
        var sources: [Source] = []
        for s in json.sources {
            guard isValidSourceKey(s.id), keys.insert(s.id).inserted else {
                throw FYError.invalidData("identificador de fonte inválido ou repetido: \(s.id.prefix(64))")
            }
            let sName = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sName.isEmpty, sName.count <= 100, !s.language.isEmpty, s.language.count <= 35 else {
                throw FYError.invalidData("fonte \(s.id) sem nome ou idioma")
            }
            sources.append(Source(id: s.id, name: sName, language: s.language, homeURL: s.homeUrl))
        }
        let config = json.config ?? [:]
        guard config.count <= 64, config.allSatisfy({ $0.key.count <= 64 && $0.value.count <= 2048 }) else {
            throw FYError.invalidData("configuração do manifesto grande demais")
        }
        return NativeExtensionManifest(format: json.format, id: json.id, name: name, versionCode: json.versionCode.value,
                                       versionName: json.versionName ?? String(json.versionCode.value),
                                       adapter: json.adapter, adapterVersion: json.adapterVersion,
                                       contentWarning: json.contentWarning?.value ?? .unspecified,
                                       sources: sources, config: config)
    }

    /// Identificador no estilo DNS reverso: letras, números, ".", "_" e "-", 3–128 caracteres.
    public static func isValidID(_ s: String) -> Bool {
        guard (3...128).contains(s.count), !s.contains(".."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    static func isValidSourceKey(_ s: String) -> Bool {
        guard (1...64).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "_-".unicodeScalars.contains($0) }
    }

    /// ID numérico estável (FNV-1a de 64 bits) para exibição junto das fontes Android.
    public static func numericID(extensionID: String, sourceID: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(extensionID)/\(sourceID)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    /// Endereço HTTPS obrigatório da configuração (sem usuário, senha ou fragmento).
    public func requireHTTPS(_ key: String) throws -> String {
        guard let value = config[key] else { throw FYError.invalidData("configuração \"\(key)\" ausente no manifesto") }
        return try Self.checkHTTPS(value, key: key)
    }

    public func optionalHTTPS(_ key: String) throws -> String? {
        guard let value = config[key], !value.isEmpty else { return nil }
        return try Self.checkHTTPS(value, key: key)
    }

    static func checkHTTPS(_ value: String, key: String) throws -> String {
        guard let comps = URLComponents(string: value), comps.scheme?.lowercased() == "https",
              let host = comps.host, !host.isEmpty, comps.user == nil, comps.password == nil, comps.fragment == nil else {
            throw FYError.insecureURL("configuração \"\(key)\" precisa ser um endereço HTTPS")
        }
        var s = value
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - Adaptadores

/// Contexto entregue aos adaptadores ao criar as fontes.
public struct AdapterContext: Sendable {
    public var http: HTTPClient
    public var includeAdult: Bool
    public var dataSaver: Bool

    public init(http: HTTPClient = URLSessionHTTPClient(), includeAdult: Bool = false, dataSaver: Bool = false) {
        self.http = http
        self.includeAdult = includeAdult
        self.dataSaver = dataSaver
    }
}

/// Adaptador nativo: código Swift compilado no app que transforma um manifesto
/// declarativo em fontes (`MangaSource`).
public protocol SourceAdapter: Sendable {
    /// Identificador usado nos manifestos (ex.: "mangadex-api-v5").
    var id: String { get }
    var displayName: String { get }
    /// Versões do esquema de configuração aceitas.
    var supportedVersions: ClosedRange<Int> { get }
    /// Confere a configuração antes de instalar.
    func validate(_ manifest: NativeExtensionManifest) throws
    func makeSources(_ manifest: NativeExtensionManifest, context: AdapterContext) throws -> [any MangaSource]
}

public enum AdapterSupport: Equatable, Sendable {
    case supported
    case unknownAdapter(String)
    case unsupportedVersion(adapter: String, requested: Int, supported: ClosedRange<Int>)

    public var isSupported: Bool { self == .supported }

    public var message: String {
        switch self {
        case .supported:
            return "Compatível"
        case .unknownAdapter(let id):
            return "Requer o adaptador \"\(id)\", que esta versão do app não tem."
        case .unsupportedVersion(let id, let requested, let supported):
            return "Requer a versão \(requested) do adaptador \"\(id)\"; esta versão do app aceita "
                + (supported.count == 1 ? "a \(supported.lowerBound)." : "de \(supported.lowerBound) a \(supported.upperBound).")
        }
    }
}

/// Adaptadores disponíveis nesta compilação do app.
public final class AdapterRegistry: @unchecked Sendable {
    private let adapters: [String: any SourceAdapter]

    public init(_ list: [any SourceAdapter]) {
        var map: [String: any SourceAdapter] = [:]
        for a in list { map[a.id] = a }
        adapters = map
    }

    /// Adaptadores revisados que acompanham o app. Nenhum deles vem ativo:
    /// só funcionam quando o usuário instala um manifesto de um repositório dele.
    public static let builtIn = AdapterRegistry([MangaDexAPIAdapter()])

    public func adapter(_ id: String) -> (any SourceAdapter)? { adapters[id] }

    public var all: [any SourceAdapter] { adapters.values.sorted { $0.id < $1.id } }

    public func support(adapter id: String, version: Int) -> AdapterSupport {
        guard let a = adapters[id] else { return .unknownAdapter(id) }
        return a.supportedVersions.contains(version)
            ? .supported
            : .unsupportedVersion(adapter: id, requested: version, supported: a.supportedVersions)
    }
}

// MARK: - Compatibilidade com iOS

public enum ExtensionCompatibility: Hashable, Sendable {
    /// Extensão nativa com adaptador disponível neste app.
    case compatible(adapter: String)
    /// Extensão nativa, mas o adaptador (ou a versão dele) não existe nesta versão do app.
    case unsupportedAdapter(String)
    /// Extensão Android (APK/JAR, código Kotlin): não roda no iOS.
    case requiresAndroid

    public var isCompatible: Bool {
        if case .compatible = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .compatible: return "Compatível com iOS"
        case .unsupportedAdapter: return "Incompatível com esta versão do app"
        case .requiresAndroid: return "Extensão Android (incompatível com iOS)"
        }
    }
}

public enum CompatibilityResolver {
    /// Uma extensão só é compatível quando é nativa E o adaptador dela existe
    /// nesta compilação. Aparecer num repositório não basta (testado).
    public static func resolve(_ e: CatalogExtension, adapters: AdapterRegistry = .builtIn) -> ExtensionCompatibility {
        guard let native = e.native else { return .requiresAndroid }
        let support = adapters.support(adapter: native.adapter, version: native.adapterVersion)
        return support.isSupported ? .compatible(adapter: native.adapter) : .unsupportedAdapter(support.message)
    }
}

// MARK: - Instalação

/// Manifesto baixado e conferido, pronto para ser gravado.
public struct NativeExtensionPackage: Sendable {
    public let manifest: NativeExtensionManifest
    /// Bytes exatamente como baixados (gravados para reativar sem rede).
    public let data: Data
    public let sha256: String
    /// `true` quando o SHA-256 foi conferido com o valor publicado no índice.
    public let integrityVerified: Bool
}

public struct NativeExtensionInstaller: Sendable {
    let catalog: ExtensionCatalogClient
    public let adapters: AdapterRegistry

    public init(catalog: ExtensionCatalogClient, adapters: AdapterRegistry = .builtIn) {
        self.catalog = catalog
        self.adapters = adapters
    }

    /// Baixa e confere o manifesto anunciado no índice.
    public func download(_ ext: CatalogExtension, allowHTTP: Bool = false) async throws -> NativeExtensionPackage {
        guard let info = ext.native else {
            throw FYError.unsupported("\(ext.name) é uma extensão Android (APK) e não pode ser instalada no iOS")
        }
        let support = adapters.support(adapter: info.adapter, version: info.adapterVersion)
        guard support.isSupported else { throw FYError.unsupported(support.message) }
        let (data, _) = try await catalog.download(info.manifestURL, allowHTTP: allowHTTP)
        return try verify(data, announcedBy: ext)
    }

    /// Confere tamanho, SHA-256 (quando publicado), formato, coerência com o
    /// índice, adaptador e configuração. Não executa nada.
    public func verify(_ data: Data, announcedBy ext: CatalogExtension?) throws -> NativeExtensionPackage {
        guard data.count <= NativeExtensionManifest.maxBytes else {
            throw FYError.invalidData("manifesto maior que \(NativeExtensionManifest.maxBytes / 1024) KB")
        }
        var verified = false
        if let expected = ext?.native?.sha256, !expected.isEmpty {
            guard SHA256.matches(data, expectedHex: expected) else {
                throw FYError.invalidData("o arquivo baixado não confere com o SHA-256 publicado pelo repositório")
            }
            verified = true
        }
        let manifest = try NativeExtensionManifest.parse(data)
        if let ext {
            guard manifest.id == ext.packageName else {
                throw FYError.invalidData("o manifesto pertence a outra extensão (\(manifest.id))")
            }
            guard manifest.versionCode == ext.versionCode else {
                throw FYError.invalidData("o manifesto tem a versão \(manifest.versionCode), mas o índice anuncia \(ext.versionCode)")
            }
            guard manifest.adapter == ext.native?.adapter, manifest.adapterVersion == ext.native?.adapterVersion else {
                throw FYError.invalidData("o manifesto usa um adaptador diferente do anunciado no índice")
            }
        }
        let support = adapters.support(adapter: manifest.adapter, version: manifest.adapterVersion)
        guard support.isSupported, let adapter = adapters.adapter(manifest.adapter) else {
            throw FYError.unsupported(support.message)
        }
        try adapter.validate(manifest)
        return NativeExtensionPackage(manifest: manifest, data: data, sha256: SHA256.hex(data), integrityVerified: verified)
    }

    /// Cria as fontes de um manifesto já instalado.
    public func makeSources(_ manifest: NativeExtensionManifest, context: AdapterContext) throws -> [any MangaSource] {
        let support = adapters.support(adapter: manifest.adapter, version: manifest.adapterVersion)
        guard support.isSupported, let adapter = adapters.adapter(manifest.adapter) else {
            throw FYError.unsupported(support.message)
        }
        try adapter.validate(manifest)
        return try adapter.makeSources(manifest, context: context)
    }
}

// MARK: - Arquivos importados pelo usuário

public enum ExtensionFileKind: Equatable, Sendable {
    /// Manifesto nativo do FreeYomi.
    case nativeManifest(NativeExtensionManifest, Data)
    /// Pacote Android (APK) ou Java (JAR): incompatível com iOS.
    case androidPackage(kind: String)
    /// Manifesto reconhecido, mas inválido.
    case invalidManifest(String)
    case unknown
}

/// Identifica um arquivo escolhido em "Importar extensão" sem executá-lo.
public enum ExtensionFileInspector {
    public static func inspect(fileAt url: URL) -> ExtensionFileKind {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? (attrs[.size] as? Int) ?? 0
        guard size > 0 else { return .unknown }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        let head = handle.readData(ofLength: 4)
        try? handle.close()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { // "PK\3\4": ZIP (APK e JAR são ZIP)
            guard let zip = try? ZipArchive(url: url) else { return .unknown }
            let names = Set(zip.entries.map(\.rawPath))
            if names.contains("AndroidManifest.xml") || names.contains("classes.dex") {
                return .androidPackage(kind: "APK")
            }
            if names.contains("META-INF/MANIFEST.MF") && names.contains(where: { $0.hasSuffix(".class") }) {
                return .androidPackage(kind: "JAR")
            }
            return .unknown
        }
        guard size <= NativeExtensionManifest.maxBytes, let data = try? Data(contentsOf: url) else {
            return size > NativeExtensionManifest.maxBytes ? .invalidManifest("arquivo grande demais para um manifesto") : .unknown
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let format = object["format"] as? String, format.hasPrefix("freeyomi.extension") else { return .unknown }
        do {
            return .nativeManifest(try NativeExtensionManifest.parse(data), data)
        } catch {
            return .invalidManifest(error.localizedDescription)
        }
    }
}

// MARK: - Adaptador: API do MangaDex (v5)

/// Interpreta manifestos de fontes compatíveis com a API pública do MangaDex v5.
///
/// Os endereços vêm do manifesto que o usuário instalou; o app não traz nenhum
/// endereço de fonte embutido. Configuração:
/// - `apiBaseUrl` (obrigatório, HTTPS)
/// - `coversBaseUrl` (obrigatório, HTTPS)
/// - `reportUrl` (opcional, HTTPS): relatório exigido pela rede de imagens
/// - `trustedImageHost` (opcional): servidores de imagem que não precisam de relatório
/// - `attribution` (opcional): crédito exibido nos detalhes da fonte
public struct MangaDexAPIAdapter: SourceAdapter {
    public let id = "mangadex-api-v5"
    public let displayName = "API MangaDex v5"
    public let supportedVersions = 1...1

    public init() {}

    func endpoints(_ m: NativeExtensionManifest) throws -> MangaDexEndpoints {
        var host = m.config["trustedImageHost"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let h = host, h.isEmpty || h.contains("/") || h.contains(":") { host = nil }
        return MangaDexEndpoints(api: try m.requireHTTPS("apiBaseUrl"), covers: try m.requireHTTPS("coversBaseUrl"),
                                 report: try m.optionalHTTPS("reportUrl"), trustedImageHost: host)
    }

    public func validate(_ m: NativeExtensionManifest) throws {
        _ = try endpoints(m)
    }

    public func makeSources(_ m: NativeExtensionManifest, context: AdapterContext) throws -> [any MangaSource] {
        let ep = try endpoints(m)
        // Um limitador por extensão, compartilhado entre as fontes (idiomas) dela.
        let limiter = RateLimiter(requestsPerSecond: 4)
        let atHome = RateLimiter(requestsPerSecond: 40.0 / 60.0)
        let attribution = m.config["attribution"].map { String($0.prefix(300)) }
        return m.sources.map { s -> any MangaSource in
            MangaDexSource(id: m.sourceID(s), name: s.name, language: s.language, includeAdult: context.includeAdult,
                           dataSaver: context.dataSaver, endpoints: ep, attribution: attribution, http: context.http,
                           limiter: limiter, atHomeLimiter: atHome)
        }
    }
}
