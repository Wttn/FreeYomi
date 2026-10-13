import Foundation
import FYCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Modelos do índice (esquema "index_v2" do Keiyoushi)
//
// O esquema foi conferido em duas frentes (ver docs/TECHNICAL_DECISIONS.md):
//  1. Código do Mihon (Apache-2.0): mihon/data/extension/model/NetworkExtensionStore.kt,
//     anotado com @ProtoNumber.
//  2. Decodificação "crua" do arquivo publicado (gzip + protobuf), que revelou
//     também o campo 501 em Resources (URL de um .jar), ausente no modelo do Mihon.
//
// Mensagem raiz (ExtensionStore):
//   1 name: string            2 badgeLabel: string     3 signingKey: string
//   4 contact: Contact        101 extensionList: ExtensionList (opcional)
//   102 extensionListUrl: string (opcional)
// Contact:      1 website, 2 discord
// ExtensionList: 1 repeated Extension
// Extension:    1 name, 2 packageName, 3 resources, 4 extensionLib (ex.: "1.6"),
//               5 versionCode (int64), 6 versionName, 7 contentWarning (enum), 8 repeated Source
// Resources:    1 apkUrl, 2 iconUrl, 501 jarUrl (observado no arquivo)
// Source:       1 id (int64), 2 name, 3 language, 4 homeUrl, 5 repeated mirrorUrls, 7 message
// ContentWarning: 0 UNSPECIFIED, 1 SAFE, 2 MIXED, 3 NSFW

public enum ContentWarning: Int, Sendable, Codable, CaseIterable {
    case unspecified = 0, safe = 1, mixed = 2, nsfw = 3

    public var label: String {
        switch self {
        case .unspecified: return "Não informado"
        case .safe: return "Seguro"
        case .mixed: return "Misto"
        case .nsfw: return "Adulto (18+)"
        }
    }
}

public struct CatalogSource: Sendable, Codable, Hashable {
    public var id: Int64
    public var name: String
    public var language: String
    public var homeURL: String
    public var mirrorURLs: [String]
    public var message: String?
}

public struct CatalogExtension: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var packageName: String
    public var apkURL: String
    public var iconURL: String
    public var jarURL: String?
    public var extensionLib: String
    public var versionCode: Int64
    public var versionName: String
    public var contentWarning: ContentWarning
    public var sources: [CatalogSource]
    public var id: String { packageName }

    /// Idiomas das fontes contidas na extensão (sem repetição, na ordem original).
    public var languages: [String] {
        var seen = Set<String>()
        return sources.map(\.language).filter { seen.insert($0).inserted }
    }

    /// Idioma "principal" derivado do pacote (eu.kanade.tachiyomi.extension.<lang>.<nome>).
    public var packageLanguage: String {
        let parts = packageName.split(separator: ".")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : (languages.first ?? "all")
    }
}

public struct ExtensionStoreIndex: Sendable, Codable, Hashable {
    public var name: String
    public var badgeLabel: String
    public var signingKey: String
    public var website: String
    public var discord: String?
    public var extensions: [CatalogExtension]
    public var extensionListURL: String?
}

// MARK: - Decodificador

public enum ExtensionIndexDecoder {
    /// Formato detectado do conteúdo baixado.
    public enum Format: Equatable, Sendable {
        case protobuf
        /// repo.json (formato antigo) com ponteiro opcional para o índice v2.
        case repoJSON(indexV2: String?)
        /// index.min.json (lista legada) — reconhecido mas não suportado.
        case legacyList
    }

    /// Remove gzip se presente e identifica o formato.
    public static func detect(_ raw: Data) throws -> (Format, Data) {
        let data = Gzip.isGzip(raw) ? try Gzip.decompress(raw) : raw
        guard let first = data.first else { throw FYError.invalidData("índice vazio") }
        switch first {
        case UInt8(ascii: "["):
            return (.legacyList, data)
        case UInt8(ascii: "{"):
            struct RepoJSON: Decodable { let index_v2: String? }
            let repo = try? JSONDecoder().decode(RepoJSON.self, from: data)
            return (.repoJSON(indexV2: repo?.index_v2), data)
        default:
            return (.protobuf, data)
        }
    }

    /// Decodifica a mensagem raiz protobuf (já descomprimida).
    public static func decodeStore(_ data: Data) throws -> ExtensionStoreIndex {
        var r = try ProtobufReader(data: data)
        var store = ExtensionStoreIndex(name: "", badgeLabel: "", signingKey: "", website: "", discord: nil,
                                        extensions: [], extensionListURL: nil)
        var sawName = false
        while let f = try r.nextField() {
            switch f.number {
            case 1: store.name = try str(f); sawName = true
            case 2: store.badgeLabel = try str(f)
            case 3: store.signingKey = try str(f)
            case 4:
                var c = try ProtobufReader(data: try bytes(f), depth: 1)
                while let cf = try c.nextField() {
                    if cf.number == 1 { store.website = try str(cf) }
                    if cf.number == 2 { store.discord = try str(cf) }
                }
            case 101: store.extensions = try decodeExtensionList(try bytes(f), depth: 1)
            case 102: store.extensionListURL = try str(f)
            default: continue // campo desconhecido: ignorado
            }
        }
        guard sawName, !store.name.isEmpty else { throw FYError.invalidData("índice sem nome do repositório") }
        return store
    }

    public static func decodeExtensionList(_ data: Data, depth: Int = 0) throws -> [CatalogExtension] {
        var r = try ProtobufReader(data: data, depth: depth)
        var result: [CatalogExtension] = []
        while let f = try r.nextField() {
            guard f.number == 1 else { continue }
            result.append(try decodeExtension(try bytes(f), depth: depth + 1))
        }
        return result
    }

    static func decodeExtension(_ data: Data, depth: Int) throws -> CatalogExtension {
        var r = try ProtobufReader(data: data, depth: depth)
        var e = CatalogExtension(name: "", packageName: "", apkURL: "", iconURL: "", jarURL: nil, extensionLib: "",
                                 versionCode: 0, versionName: "", contentWarning: .unspecified, sources: [])
        while let f = try r.nextField() {
            switch f.number {
            case 1: e.name = try str(f)
            case 2: e.packageName = try str(f)
            case 3:
                var res = try ProtobufReader(data: try bytes(f), depth: depth + 1)
                while let rf = try res.nextField() {
                    switch rf.number {
                    case 1: e.apkURL = try str(rf)
                    case 2: e.iconURL = try str(rf)
                    case 501: e.jarURL = try str(rf)
                    default: continue
                    }
                }
            case 4: e.extensionLib = try str(f)
            case 5: e.versionCode = try int(f)
            case 6: e.versionName = try str(f)
            case 7: e.contentWarning = ContentWarning(rawValue: Int(try int(f))) ?? .unspecified
            case 8: e.sources.append(try decodeSource(try bytes(f), depth: depth + 1))
            default: continue
            }
        }
        guard !e.packageName.isEmpty else { throw FYError.invalidData("extensão sem packageName") }
        return e
    }

    static func decodeSource(_ data: Data, depth: Int) throws -> CatalogSource {
        var r = try ProtobufReader(data: data, depth: depth)
        var s = CatalogSource(id: 0, name: "", language: "", homeURL: "", mirrorURLs: [], message: nil)
        while let f = try r.nextField() {
            switch f.number {
            case 1: s.id = try int(f)
            case 2: s.name = try str(f)
            case 3: s.language = try str(f)
            case 4: s.homeURL = try str(f)
            case 5: s.mirrorURLs.append(try str(f))
            case 7: s.message = try str(f)
            default: continue
            }
        }
        return s
    }

    private static func str(_ f: ProtobufReader.Field) throws -> String {
        guard let s = f.value.string else { throw FYError.invalidData("campo \(f.number) deveria ser texto") }
        return s
    }

    private static func bytes(_ f: ProtobufReader.Field) throws -> Data {
        guard let d = f.value.data else { throw FYError.invalidData("campo \(f.number) deveria ser mensagem") }
        return d
    }

    private static func int(_ f: ProtobufReader.Field) throws -> Int64 {
        guard let v = f.value.int64 else { throw FYError.invalidData("campo \(f.number) deveria ser inteiro") }
        return v
    }
}

// MARK: - Compatibilidade com iOS

public enum ExtensionCompatibility: Hashable, Sendable {
    /// Existe um adaptador nativo do FreeYomi para esta extensão.
    case nativeAdapter(sourceId: String)
    /// A extensão é código Kotlin/Android (APK/JAR) e não pode rodar no iOS.
    case requiresAndroid

    public var label: String {
        switch self {
        case .nativeAdapter: return "Compatível (adaptador nativo)"
        case .requiresAndroid: return "Requer Android"
        }
    }
}

public enum CompatibilityResolver {
    /// Mapeamento explícito `packageName` → fonte nativa. Uma extensão só é
    /// considerada compatível quando um adaptador Swift foi escrito e testado.
    /// Nenhuma entrada por enquanto (Fase 3).
    public static var nativeAdapters: [String: String] = [:]

    public static func resolve(_ e: CatalogExtension) -> ExtensionCompatibility {
        if let id = nativeAdapters[e.packageName] { return .nativeAdapter(sourceId: id) }
        return .requiresAndroid
    }
}

// MARK: - Cliente com cache

public struct CatalogSnapshot: Sendable {
    public let index: ExtensionStoreIndex
    /// URL efetivamente usada (após seguir repo.json → index_v2).
    public let sourceURL: String
    public let fetchedAt: Date
    /// `true` quando os dados vieram do cache local porque a rede falhou.
    public let isFromCache: Bool
    /// Erro de rede que levou ao uso do cache, se houver.
    public let networkError: String?
}

/// Baixa, valida, decodifica e guarda em cache o índice de extensões.
/// Cada repositório tem o próprio cache (chave = URL informada pelo usuário).
public final class ExtensionCatalogClient: @unchecked Sendable {
    private let http: HTTPClient
    private let cacheDirectory: URL
    private let fm = FileManager.default

    public init(http: HTTPClient, cacheDirectory: URL) {
        self.http = http
        self.cacheDirectory = cacheDirectory
    }

    private func stem(_ key: String) -> String {
        String(DiskCache.fileName(for: RepositoryURL.canonicalKey(key)).dropLast(4)) // sem ".bin"
    }
    private func cacheFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("catalog-\(stem(key)).pb") }
    private func metaFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("catalog-\(stem(key)).json") }

    struct Meta: Codable { let sourceURL: String; let fetchedAt: Date }

    /// Busca o índice na rede. Se falhar, recorre ao cache daquele repositório (se existir).
    public func refresh(from urlString: String) async throws -> CatalogSnapshot {
        do {
            return try await fetch(urlString, cacheKey: urlString, redirectsLeft: 2)
        } catch FYError.cancelled {
            throw FYError.cancelled
        } catch {
            if let cached = try? loadCache(for: urlString) {
                return CatalogSnapshot(index: cached.index, sourceURL: cached.sourceURL, fetchedAt: cached.fetchedAt,
                                       isFromCache: true, networkError: error.localizedDescription)
            }
            throw error
        }
    }

    /// Atualiza vários repositórios em paralelo; a ordem da entrada é preservada
    /// e a falha de um não impede os demais.
    public func refreshAll(_ urls: [String]) async -> [RepositoryCatalog] {
        await withTaskGroup(of: (Int, RepositoryCatalog).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    do {
                        let snap = try await self.refresh(from: url)
                        return (i, RepositoryCatalog(indexURL: url, snapshot: snap, error: nil))
                    } catch {
                        return (i, RepositoryCatalog(indexURL: url, snapshot: nil, error: error.localizedDescription))
                    }
                }
            }
            var out = [(Int, RepositoryCatalog)]()
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Últimos índices salvos de cada repositório, sem rede.
    public func cachedAll(_ urls: [String]) -> [RepositoryCatalog] {
        urls.map { url in
            if let s = try? loadCache(for: url) { return RepositoryCatalog(indexURL: url, snapshot: s, error: nil) }
            return RepositoryCatalog(indexURL: url, snapshot: nil, error: nil)
        }
    }

    private func fetch(_ urlString: String, cacheKey: String, redirectsLeft: Int) async throws -> CatalogSnapshot {
        guard let url = URL(string: urlString) else { throw FYError.invalidData("URL do repositório inválida") }
        try URLPolicy.validateRemote(url)
        let response = try await http.get(url, headers: [:])
        guard (200..<300).contains(response.statusCode) else {
            throw FYError.httpStatus(response.statusCode, url: Redactor.redact(url))
        }
        let (format, data) = try ExtensionIndexDecoder.detect(response.body)
        switch format {
        case .legacyList:
            throw FYError.unsupported("formato legado index.min.json; use a URL do repo.json ou do index.pb")
        case .repoJSON(let next):
            guard let next, redirectsLeft > 0 else {
                throw FYError.unsupported("repo.json sem o campo index_v2")
            }
            return try await fetch(next, cacheKey: cacheKey, redirectsLeft: redirectsLeft - 1)
        case .protobuf:
            let index = try ExtensionIndexDecoder.decodeStore(data)
            let now = Date()
            try? saveCache(raw: data, meta: Meta(sourceURL: urlString, fetchedAt: now), key: cacheKey)
            return CatalogSnapshot(index: index, sourceURL: urlString, fetchedAt: now, isFromCache: false,
                                   networkError: nil)
        }
    }

    /// Lê o último índice salvo de um repositório, sem rede.
    public func loadCache(for urlString: String) throws -> CatalogSnapshot {
        let raw = try Data(contentsOf: cacheFile(urlString))
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaFile(urlString)))
        let index = try ExtensionIndexDecoder.decodeStore(raw)
        return CatalogSnapshot(index: index, sourceURL: meta.sourceURL, fetchedAt: meta.fetchedAt, isFromCache: true,
                               networkError: nil)
    }

    /// Apaga o cache de um repositório removido.
    public func removeCache(for urlString: String) {
        try? fm.removeItem(at: cacheFile(urlString))
        try? fm.removeItem(at: metaFile(urlString))
    }

    private func saveCache(raw: Data, meta: Meta, key: String) throws {
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try raw.write(to: cacheFile(key), options: .atomic)
        try JSONEncoder().encode(meta).write(to: metaFile(key), options: .atomic)
    }
}

/// Resultado do catálogo de um repositório (ou o erro, isolado).
public struct RepositoryCatalog: Sendable, Identifiable {
    public let indexURL: String
    public let snapshot: CatalogSnapshot?
    public let error: String?
    public var id: String { indexURL }

    public init(indexURL: String, snapshot: CatalogSnapshot?, error: String?) {
        self.indexURL = indexURL
        self.snapshot = snapshot
        self.error = error
    }

    public var repository: ExtensionRepository {
        if let s = snapshot { return ExtensionRepository(indexURL: indexURL, index: s.index) }
        return ExtensionRepository(indexURL: indexURL, name: RepositoryURL.displayName(indexURL))
    }
}
