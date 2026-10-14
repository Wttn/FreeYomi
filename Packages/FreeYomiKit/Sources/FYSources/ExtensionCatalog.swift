import Foundation
import FYCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Formatos de índice suportados
//
// Conferidos no código do Mihon (Apache-2.0, commit 446f6df):
// mihon/data/extension/service/ExtensionStoreService.kt e mihon/data/extension/model/*.kt,
// e nos arquivos publicados por um repositório real (branch "repo"). Nenhuma
// linha foi copiada; nomes e números de campo são fatos de interoperabilidade.
//
// 1. index.pb — protobuf da mensagem ExtensionStore (às vezes com gzip):
//      1 name  2 badgeLabel  3 signingKey  4 contact{1 website, 2 discord}
//      101 extensionList{1 repeated Extension}  102 extensionListUrl
//    Extension: 1 name, 2 packageName, 3 resources{1 apkUrl, 2 iconUrl, 501 jarUrl},
//               4 extensionLib, 5 versionCode, 6 versionName, 7 contentWarning, 8 repeated Source
//    Source:    1 id (int64), 2 name, 3 language, 4 homeUrl, 5 repeated mirrorUrls, 7 message
//    ContentWarning: 0 UNSPECIFIED, 1 SAFE, 2 MIXED, 3 NSFW
//    (o campo 501 está nos arquivos publicados, mas não no modelo do Mihon)
// 2. index.json — a mesma mensagem em JSON proto3: nomes em camelCase, int64
//    como texto ("106004") e enums pelo nome ("CONTENT_WARNING_NSFW").
// 3. repo.json (legado) — {"index_v2": "<url do índice novo>"?, "meta": {name,
//    shortName?, website, signingKeyFingerprint}}. Com index_v2, segue para ele;
//    sem, a lista fica em <base>/index.min.json.
// 4. index.min.json (legado) — lista JSON [{name, pkg, apk, lang, code, version,
//    nsfw, sources?[{name, lang, id, baseUrl}]}]; apk e ícone ficam em
//    <base>/apk/<apk> e <base>/icon/<pkg>.png.
// 5. freeyomi.repository.v1 — formato próprio para fontes nativas do iOS
//    (manifestos declarativos executados por adaptadores Swift compilados no
//    app). Ver NativeExtensions.swift e docs/EXTENSIONS_ARCHITECTURE.md.

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

    /// Aceita o nome proto3 ("CONTENT_WARNING_NSFW"), o nome curto ("NSFW") ou o número.
    public init(flexible text: String) {
        let t = text.uppercased().replacingOccurrences(of: "CONTENT_WARNING_", with: "")
        switch t {
        case "SAFE", "1": self = .safe
        case "MIXED", "2": self = .mixed
        case "NSFW", "3": self = .nsfw
        default: self = .unspecified
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
    /// Identificador textual (fontes nativas do FreeYomi, ex.: "main").
    public var key: String? = nil
}

/// Dados de uma extensão nativa do FreeYomi no índice do repositório.
public struct NativeExtensionInfo: Sendable, Codable, Hashable {
    /// Adaptador Swift que interpreta o manifesto (ex.: "mangadex-api-v5").
    public var adapter: String
    public var adapterVersion: Int
    /// Endereço do manifesto declarativo (`freeyomi.extension.v1`).
    public var manifestURL: String
    /// SHA-256 do manifesto, em hexadecimal, quando o repositório informa.
    public var sha256: String?
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
    /// Presente só em extensões nativas do FreeYomi; `nil` = extensão Android (APK/JAR).
    public var native: NativeExtensionInfo? = nil
    public var id: String { packageName }

    public init(name: String, packageName: String, apkURL: String, iconURL: String, jarURL: String?,
                extensionLib: String, versionCode: Int64, versionName: String, contentWarning: ContentWarning,
                sources: [CatalogSource], native: NativeExtensionInfo? = nil) {
        self.name = name
        self.packageName = packageName
        self.apkURL = apkURL
        self.iconURL = iconURL
        self.jarURL = jarURL
        self.extensionLib = extensionLib
        self.versionCode = versionCode
        self.versionName = versionName
        self.contentWarning = contentWarning
        self.sources = sources
        self.native = native
    }

    public var isNative: Bool { native != nil }

    /// Idiomas das fontes contidas na extensão (sem repetição, na ordem original).
    public var languages: [String] {
        var seen = Set<String>()
        return sources.map(\.language).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Idioma "principal" derivado do pacote (eu.kanade.tachiyomi.extension.<lang>.<nome>).
    public var packageLanguage: String {
        if isNative { return languages.count == 1 ? languages[0] : "all" }
        let parts = packageName.split(separator: ".")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : (languages.first ?? "all")
    }
}

/// Formato em que o índice foi publicado.
public enum RepositoryIndexFormat: String, Sendable, Codable, CaseIterable {
    case protobuf
    case storeJSON
    case legacyJSON
    case freeyomi

    public var label: String {
        switch self {
        case .protobuf: return "index.pb (protobuf)"
        case .storeJSON: return "index.json"
        case .legacyJSON: return "index.min.json (legado)"
        case .freeyomi: return "FreeYomi (fontes nativas)"
        }
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
    public var format: RepositoryIndexFormat = .protobuf
    /// Entradas ignoradas por estarem incompletas (sem identificador, por exemplo).
    public var skippedEntries: Int = 0
}

// MARK: - Decodificador

public enum ExtensionIndexDecoder {
    /// Formato detectado do conteúdo baixado.
    public enum Format: Equatable, Sendable {
        case protobuf
        /// Índice nativo do FreeYomi (`"format": "freeyomi.repository.v1"`).
        case freeyomi
        /// repo.json (legado), com ponteiro opcional para o índice novo.
        case repoJSON(indexV2: String?)
        /// index.json (ExtensionStore em JSON proto3).
        case storeJSON
        /// index.min.json (lista legada).
        case legacyList
    }

    /// Remove gzip se presente e identifica o formato.
    public static func detect(_ raw: Data, maxDecompressed: Int = Gzip.defaultMaxOutput) throws -> (Format, Data) {
        let data = Gzip.isGzip(raw) ? try Gzip.decompress(raw, maxOutput: maxDecompressed) : raw
        guard let rawFirst = data.first else { throw FYError.invalidData("índice vazio") }
        // Texto pode começar com espaços ou com o BOM do UTF-8. Um protobuf
        // também pode começar com 0x0A (campo 1), por isso o texto só é
        // considerado quando o conteúdo inteiro é UTF-8 válido.
        let ignorable: Set<UInt8> = [0x20, 0x0A, 0x0D, 0x09, 0xEF, 0xBB, 0xBF]
        var first = rawFirst
        if ignorable.contains(rawFirst), let text = String(data: data, encoding: .utf8) {
            let trimmed = text.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
            guard let c = trimmed.first else { throw FYError.invalidData("índice vazio") }
            if c == "[" || c == "{" || c == "<" { first = c.asciiValue ?? rawFirst }
        }
        switch first {
        case UInt8(ascii: "["):
            return (.legacyList, data)
        case UInt8(ascii: "{"):
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw FYError.invalidData("JSON malformado")
            }
            if let format = object["format"] as? String, format.hasPrefix("freeyomi.repository") {
                return (.freeyomi, data)
            }
            if object["index_v2"] != nil || object["meta"] != nil {
                return (.repoJSON(indexV2: object["index_v2"] as? String), data)
            }
            return (.storeJSON, data)
        case UInt8(ascii: "<"):
            throw FYError.invalidData("o endereço devolveu uma página HTML, não um índice de extensões")
        default:
            return (.protobuf, data)
        }
    }

    // MARK: Protobuf (index.pb)

    /// Decodifica a mensagem raiz protobuf (já descomprimida).
    public static func decodeStore(_ data: Data) throws -> ExtensionStoreIndex {
        var r = try ProtobufReader(data: data)
        var store = ExtensionStoreIndex(name: "", badgeLabel: "", signingKey: "", website: "", discord: nil,
                                        extensions: [], extensionListURL: nil, format: .protobuf)
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

    // MARK: JSON proto3 (index.json)

    /// Inteiro de 64 bits em JSON proto3: pode vir como número ou como texto.
    struct FlexInt64: Decodable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int64.self) {
                value = i
            } else if let s = try? c.decode(String.self), let i = Int64(s.trimmingCharacters(in: .whitespaces)) {
                value = i
            } else if let d = try? c.decode(Double.self), d.rounded() == d, abs(d) < 9.0e18 {
                value = Int64(d)
            } else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "inteiro inválido")
            }
        }
    }

    /// Aviso de conteúdo: nome do enum ou número.
    struct FlexWarning: Decodable {
        let value: ContentWarning
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) {
                value = ContentWarning(rawValue: i) ?? .unspecified
            } else if let s = try? c.decode(String.self) {
                value = ContentWarning(flexible: s)
            } else {
                value = .unspecified
            }
        }
    }

    struct StoreJSON: Decodable {
        let name: String?
        let badgeLabel: String?
        let signingKey: String?
        let contact: Contact?
        let extensionList: ListJSON?
        let extensionListUrl: String?

        struct Contact: Decodable { let website: String?; let discord: String? }
    }

    struct ListJSON: Decodable { let extensions: [Lenient<ExtensionJSON>]? }

    struct ExtensionJSON: Decodable {
        let name: String?
        let packageName: String?
        let resources: Resources?
        let extensionLib: String?
        let versionCode: FlexInt64?
        let versionName: String?
        let contentWarning: FlexWarning?
        let sources: [Lenient<SourceJSON>]?

        struct Resources: Decodable { let apkUrl: String?; let iconUrl: String?; let jarUrl: String? }
    }

    struct SourceJSON: Decodable {
        let id: FlexInt64?
        let name: String?
        let language: String?
        let homeUrl: String?
        let mirrorUrls: [String]?
        let message: String?
    }

    /// Decodifica um elemento sem derrubar a lista inteira quando ele é inválido.
    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    public static func decodeStoreJSON(_ data: Data) throws -> ExtensionStoreIndex {
        let json: StoreJSON
        do {
            json = try JSONDecoder().decode(StoreJSON.self, from: data)
        } catch {
            throw FYError.invalidData("index.json com estrutura inesperada")
        }
        guard let name = json.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw FYError.invalidData("índice sem nome do repositório")
        }
        var store = ExtensionStoreIndex(name: name, badgeLabel: json.badgeLabel ?? "", signingKey: json.signingKey ?? "",
                                        website: json.contact?.website ?? "", discord: json.contact?.discord,
                                        extensions: [], extensionListURL: json.extensionListUrl, format: .storeJSON)
        if let list = json.extensionList {
            let (exts, skipped) = mapListJSON(list)
            store.extensions = exts
            store.skippedEntries = skipped
        }
        return store
    }

    /// Lista separada (campo 102), em JSON.
    public static func decodeExtensionListJSON(_ data: Data) throws -> (extensions: [CatalogExtension], skipped: Int) {
        do {
            return mapListJSON(try JSONDecoder().decode(ListJSON.self, from: data))
        } catch {
            throw FYError.invalidData("lista de extensões com estrutura inesperada")
        }
    }

    static func mapListJSON(_ list: ListJSON) -> ([CatalogExtension], Int) {
        var out: [CatalogExtension] = []
        var skipped = 0
        for item in list.extensions ?? [] {
            guard let e = item.value, let pkg = e.packageName, !pkg.isEmpty else { skipped += 1; continue }
            let sources: [CatalogSource] = (e.sources ?? []).compactMap { $0.value }.map {
                CatalogSource(id: $0.id?.value ?? 0, name: $0.name ?? "", language: $0.language ?? "",
                              homeURL: $0.homeUrl ?? "", mirrorURLs: $0.mirrorUrls ?? [], message: $0.message)
            }
            out.append(CatalogExtension(name: e.name ?? pkg, packageName: pkg, apkURL: e.resources?.apkUrl ?? "",
                                        iconURL: e.resources?.iconUrl ?? "", jarURL: e.resources?.jarUrl,
                                        extensionLib: e.extensionLib ?? "", versionCode: e.versionCode?.value ?? 0,
                                        versionName: e.versionName ?? "", contentWarning: e.contentWarning?.value ?? .unspecified,
                                        sources: sources))
        }
        return (out, skipped)
    }

    // MARK: Legado (repo.json + index.min.json)

    public struct LegacyRepoMeta: Sendable, Equatable {
        public var name: String
        public var shortName: String?
        public var website: String
        public var signingKeyFingerprint: String
    }

    struct LegacyRepoJSON: Decodable {
        let index_v2: String?
        let meta: Meta?
        struct Meta: Decodable {
            let name: String?
            let shortName: String?
            let website: String?
            let signingKeyFingerprint: String?
        }
    }

    /// Lê o repo.json legado: ponteiro para o índice novo e/ou metadados.
    public static func decodeLegacyRepo(_ data: Data) throws -> (indexV2: String?, meta: LegacyRepoMeta?) {
        guard let repo = try? JSONDecoder().decode(LegacyRepoJSON.self, from: data) else {
            throw FYError.invalidData("repo.json com estrutura inesperada")
        }
        var meta: LegacyRepoMeta?
        if let m = repo.meta, let name = m.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            meta = LegacyRepoMeta(name: name, shortName: m.shortName, website: m.website ?? "",
                                  signingKeyFingerprint: m.signingKeyFingerprint ?? "")
        }
        let next = repo.index_v2.flatMap { $0.isEmpty ? nil : $0 }
        guard next != nil || meta != nil else { throw FYError.invalidData("repo.json sem index_v2 e sem meta.name") }
        return (next, meta)
    }

    struct LegacyExtensionJSON: Decodable {
        let name: String?
        let pkg: String?
        let apk: String?
        let lang: String?
        let code: FlexInt64?
        let version: String?
        let nsfw: FlexInt64?
        let sources: [Lenient<LegacySourceJSON>]?
    }

    struct LegacySourceJSON: Decodable {
        let name: String?
        let lang: String?
        let id: FlexInt64?
        let baseUrl: String?
    }

    /// Lê o index.min.json. `baseURL` é a pasta do repositório (sem barra final).
    public static func decodeLegacyList(_ data: Data, baseURL: String,
                                        meta: LegacyRepoMeta?) throws -> ExtensionStoreIndex {
        let list: [Lenient<LegacyExtensionJSON>]
        do {
            list = try JSONDecoder().decode([Lenient<LegacyExtensionJSON>].self, from: data)
        } catch {
            throw FYError.invalidData("index.min.json com estrutura inesperada")
        }
        var out: [CatalogExtension] = []
        var skipped = 0
        for item in list {
            guard let e = item.value, let pkg = e.pkg, !pkg.isEmpty else { skipped += 1; continue }
            var name = e.name ?? pkg
            if name.hasPrefix("Tachiyomi: ") { name = String(name.dropFirst("Tachiyomi: ".count)) }
            let version = e.version ?? ""
            let lang = e.lang ?? ""
            var sources: [CatalogSource] = (e.sources ?? []).compactMap { $0.value }.map {
                CatalogSource(id: $0.id?.value ?? 0, name: $0.name ?? name, language: $0.lang ?? lang,
                              homeURL: $0.baseUrl ?? "", mirrorURLs: [], message: nil)
            }
            if sources.isEmpty {
                sources = [CatalogSource(id: 0, name: name, language: lang, homeURL: "", mirrorURLs: [], message: nil)]
            }
            let lib = version.split(separator: ".").dropLast().joined(separator: ".")
            out.append(CatalogExtension(
                name: name, packageName: pkg,
                apkURL: safeFileName(e.apk).map { "\(baseURL)/apk/\($0)" } ?? "",
                iconURL: safeFileName(pkg + ".png").map { "\(baseURL)/icon/\($0)" } ?? "",
                jarURL: nil, extensionLib: lib, versionCode: e.code?.value ?? 0, versionName: version,
                contentWarning: e.nsfw?.value == 1 ? .nsfw : .safe, sources: sources))
        }
        if out.isEmpty && skipped > 0 { throw FYError.invalidData("nenhuma extensão válida no index.min.json") }
        return ExtensionStoreIndex(name: meta?.name ?? RepositoryURL.displayName(baseURL),
                                   badgeLabel: meta?.shortName ?? "", signingKey: meta?.signingKeyFingerprint ?? "",
                                   website: meta?.website ?? "", discord: nil, extensions: out, extensionListURL: nil,
                                   format: .legacyJSON, skippedEntries: skipped)
    }

    /// Nome de arquivo simples (sem pastas, sem "..", sem esquema).
    static func safeFileName(_ name: String?) -> String? {
        guard let name, !name.isEmpty, name.count <= 255, !name.contains("/"), !name.contains("\\"),
              !name.contains(".."), !name.contains(":"), !name.contains("?"), !name.contains("#") else { return nil }
        return name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    // MARK: Formato nativo do FreeYomi

    struct FreeYomiRepoJSON: Decodable {
        let format: String
        let name: String?
        let badgeLabel: String?
        let website: String?
        let discord: String?
        let signingKey: String?
        let extensions: [Lenient<FreeYomiExtensionJSON>]?
    }

    struct FreeYomiExtensionJSON: Decodable {
        let id: String
        let name: String
        let versionCode: FlexInt64
        let versionName: String?
        let language: String?
        let contentWarning: FlexWarning?
        let iconUrl: String?
        let adapter: String
        let adapterVersion: Int
        let manifestUrl: String
        let sha256: String?
        let sources: [Lenient<FreeYomiSourceJSON>]?
    }

    struct FreeYomiSourceJSON: Decodable {
        let id: String
        let name: String
        let language: String
        let homeUrl: String?
    }

    /// Versões do formato do índice que este app entende.
    public static let supportedFreeYomiFormats: Set<String> = ["freeyomi.repository.v1"]

    public static func decodeFreeYomi(_ data: Data, indexURL: URL) throws -> ExtensionStoreIndex {
        let json: FreeYomiRepoJSON
        do {
            json = try JSONDecoder().decode(FreeYomiRepoJSON.self, from: data)
        } catch {
            throw FYError.invalidData("índice FreeYomi com estrutura inesperada")
        }
        guard supportedFreeYomiFormats.contains(json.format) else {
            throw FYError.unsupported("formato \(json.format) é mais novo que este app; atualize o FreeYomi")
        }
        guard let name = json.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw FYError.invalidData("índice sem nome do repositório")
        }
        var out: [CatalogExtension] = []
        var skipped = 0
        var seen = Set<String>()
        for item in json.extensions ?? [] {
            guard let e = item.value, NativeExtensionManifest.isValidID(e.id), !e.name.isEmpty,
                  let manifest = resolve(e.manifestUrl, against: indexURL), seen.insert(e.id).inserted else {
                skipped += 1
                continue
            }
            let lang = e.language ?? ""
            let sources = (e.sources ?? []).compactMap { $0.value }.map {
                CatalogSource(id: NativeExtensionManifest.numericID(extensionID: e.id, sourceID: $0.id), name: $0.name,
                              language: $0.language, homeURL: $0.homeUrl ?? "", mirrorURLs: [], message: nil, key: $0.id)
            }
            out.append(CatalogExtension(
                name: e.name, packageName: e.id, apkURL: "",
                iconURL: e.iconUrl.flatMap { resolve($0, against: indexURL) } ?? "",
                jarURL: nil, extensionLib: "\(e.adapter)@\(e.adapterVersion)", versionCode: e.versionCode.value,
                versionName: e.versionName ?? String(e.versionCode.value),
                contentWarning: e.contentWarning?.value ?? .unspecified,
                sources: sources.isEmpty
                    ? [CatalogSource(id: 0, name: e.name, language: lang, homeURL: "", mirrorURLs: [], message: nil)]
                    : sources,
                native: NativeExtensionInfo(adapter: e.adapter, adapterVersion: e.adapterVersion, manifestURL: manifest,
                                            sha256: e.sha256)))
        }
        if out.isEmpty && skipped > 0 { throw FYError.invalidData("nenhuma extensão válida no índice FreeYomi") }
        return ExtensionStoreIndex(name: name, badgeLabel: json.badgeLabel ?? "", signingKey: json.signingKey ?? "",
                                   website: json.website ?? "", discord: json.discord, extensions: out,
                                   extensionListURL: nil, format: .freeyomi, skippedEntries: skipped)
    }

    /// Resolve endereços relativos ao índice. Só aceita http(s).
    public static func resolve(_ s: String, against base: URL) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url.absoluteString
    }
}

// MARK: - Cliente com cache

/// Limites aplicados a tudo que vem de um repositório (dados não confiáveis).
public struct CatalogLimits: Sendable {
    /// Tamanho máximo da resposta baixada.
    public var maxDownloadBytes = 20 * 1024 * 1024
    /// Tamanho máximo depois de descomprimir (proteção contra "gzip bomb").
    public var maxDecompressedBytes = 64 * 1024 * 1024
    /// Quantidade máxima de extensões por repositório.
    public var maxExtensions = 25_000
    /// Tempo limite de cada requisição (segundos).
    public var timeout: TimeInterval = 30
    /// Quantos saltos repo.json → índice novo / lista separada são seguidos.
    public var maxIndirections = 3
    public init() {}
}

public struct CatalogSnapshot: Sendable {
    public let index: ExtensionStoreIndex
    /// URL efetivamente usada (após seguir repo.json → index_v2).
    public let sourceURL: String
    public let fetchedAt: Date
    /// `true` quando os dados vieram do cache local porque a rede falhou.
    public let isFromCache: Bool
    /// Erro de rede que levou ao uso do cache, se houver.
    public let networkError: String?

    public init(index: ExtensionStoreIndex, sourceURL: String, fetchedAt: Date, isFromCache: Bool, networkError: String?) {
        self.index = index
        self.sourceURL = sourceURL
        self.fetchedAt = fetchedAt
        self.isFromCache = isFromCache
        self.networkError = networkError
    }

    public var format: RepositoryIndexFormat { index.format }
}

/// Baixa, valida, decodifica e guarda em cache o índice de extensões.
/// Cada repositório tem o próprio cache (chave = URL informada pelo usuário).
public final class ExtensionCatalogClient: @unchecked Sendable {
    private let http: HTTPClient
    private let cacheDirectory: URL
    public let limits: CatalogLimits
    private let fm = FileManager.default

    public init(http: HTTPClient, cacheDirectory: URL, limits: CatalogLimits = CatalogLimits()) {
        self.http = http
        self.cacheDirectory = cacheDirectory
        self.limits = limits
    }

    private func stem(_ key: String) -> String {
        String(DiskCache.fileName(for: RepositoryURL.canonicalKey(key)).dropLast(4)) // sem ".bin"
    }
    private func indexFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("repo-\(stem(key)).index.json") }
    private func metaFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("repo-\(stem(key)).meta.json") }
    // Cache das versões 0.3.x (só protobuf).
    private func legacyCacheFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("catalog-\(stem(key)).pb") }
    private func legacyMetaFile(_ key: String) -> URL { cacheDirectory.appendingPathComponent("catalog-\(stem(key)).json") }

    struct Meta: Codable { let sourceURL: String; let fetchedAt: Date }

    /// Baixa e valida o índice, sem gravar nada (usado em "Validar").
    public func fetch(from urlString: String, allowHTTP: Bool = false) async throws -> CatalogSnapshot {
        let (index, used) = try await fetchIndex(urlString, allowHTTP: allowHTTP, hopsLeft: limits.maxIndirections)
        return CatalogSnapshot(index: index, sourceURL: used, fetchedAt: Date(), isFromCache: false, networkError: nil)
    }

    /// Busca o índice na rede e grava no cache. Se a rede falhar, recorre ao
    /// cache daquele repositório (se existir), informando o erro.
    public func refresh(from urlString: String, allowHTTP: Bool = false) async throws -> CatalogSnapshot {
        do {
            let snap = try await fetch(from: urlString, allowHTTP: allowHTTP)
            try? save(snap, for: urlString)
            return snap
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
    public func refreshAll(_ urls: [String], allowHTTP: Set<String> = []) async -> [RepositoryCatalog] {
        await withTaskGroup(of: (Int, RepositoryCatalog).self) { group in
            for (i, url) in urls.enumerated() {
                let http = allowHTTP.contains(url)
                group.addTask {
                    do {
                        let snap = try await self.refresh(from: url, allowHTTP: http)
                        return (i, RepositoryCatalog(indexURL: url, snapshot: snap, error: snap.networkError))
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

    // MARK: Rede

    /// Destinos aceitos: HTTPS; HTTP só com permissão explícita. Nunca aceita
    /// rebaixamento de HTTPS para HTTP em redirecionamentos.
    static func validate(_ url: URL, allowHTTP: Bool) throws {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw FYError.insecureURL(Redactor.redact(url))
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" || (scheme == "http" && allowHTTP) { return }
        throw FYError.insecureURL(Redactor.redact(url))
    }

    /// Baixa um recurso do repositório aplicando os limites.
    public func download(_ urlString: String, allowHTTP: Bool) async throws -> (data: Data, finalURL: URL) {
        guard let url = URL(string: urlString) else { throw FYError.invalidData("URL do repositório inválida") }
        try Self.validate(url, allowHTTP: allowHTTP)
        if Task.isCancelled { throw FYError.cancelled }
        let response: HTTPResponse
        do {
            response = try await http.send(HTTPRequest(url: url, timeout: limits.timeout))
        } catch is CancellationError {
            throw FYError.cancelled
        }
        let final = response.finalURL ?? url
        // HTTP só continua valendo se o endereço original já era HTTP.
        try Self.validate(final, allowHTTP: allowHTTP && url.scheme?.lowercased() == "http")
        guard (200..<300).contains(response.statusCode) else {
            throw FYError.httpStatus(response.statusCode, url: Redactor.redact(url))
        }
        guard response.body.count <= limits.maxDownloadBytes else {
            throw FYError.invalidData("arquivo maior que o limite de \(Self.sizeLabel(limits.maxDownloadBytes))")
        }
        return (response.body, final)
    }

    private func fetchIndex(_ urlString: String, allowHTTP: Bool, hopsLeft: Int) async throws -> (ExtensionStoreIndex, String) {
        let (raw, finalURL) = try await download(urlString, allowHTTP: allowHTTP)
        let (format, data) = try ExtensionIndexDecoder.detect(raw, maxDecompressed: limits.maxDecompressedBytes)
        var index: ExtensionStoreIndex
        switch format {
        case .protobuf:
            index = try ExtensionIndexDecoder.decodeStore(data)
            try await loadSeparateList(&index, base: finalURL, allowHTTP: allowHTTP, hopsLeft: hopsLeft)
        case .storeJSON:
            index = try ExtensionIndexDecoder.decodeStoreJSON(data)
            try await loadSeparateList(&index, base: finalURL, allowHTTP: allowHTTP, hopsLeft: hopsLeft)
        case .freeyomi:
            index = try ExtensionIndexDecoder.decodeFreeYomi(data, indexURL: finalURL)
        case .repoJSON:
            let (next, meta) = try ExtensionIndexDecoder.decodeLegacyRepo(data)
            if let next {
                guard hopsLeft > 0, let target = ExtensionIndexDecoder.resolve(next, against: finalURL) else {
                    throw FYError.invalidData("repo.json aponta para um endereço inválido")
                }
                return try await fetchIndex(target, allowHTTP: allowHTTP, hopsLeft: hopsLeft - 1)
            }
            let base = Self.folder(of: finalURL)
            let (listRaw, _) = try await download(base + "/index.min.json", allowHTTP: allowHTTP)
            let (_, listData) = try ExtensionIndexDecoder.detect(listRaw, maxDecompressed: limits.maxDecompressedBytes)
            index = try ExtensionIndexDecoder.decodeLegacyList(listData, baseURL: base, meta: meta)
        case .legacyList:
            // Como no Mihon: o repo.json ao lado diz o nome e, se existir, o índice novo.
            let base = Self.folder(of: finalURL)
            var meta: ExtensionIndexDecoder.LegacyRepoMeta?
            if hopsLeft > 0, let repo = await legacyRepoJSON(base: base, allowHTTP: allowHTTP) {
                if let next = repo.indexV2,
                   let newer = try? await fetchIndex(next, allowHTTP: allowHTTP, hopsLeft: hopsLeft - 1) {
                    return newer
                }
                meta = repo.meta
            }
            index = try ExtensionIndexDecoder.decodeLegacyList(data, baseURL: base, meta: meta)
        }
        guard index.extensions.count <= limits.maxExtensions else {
            throw FYError.invalidData("o índice tem mais de \(limits.maxExtensions) extensões")
        }
        return (index, finalURL.absoluteString)
    }

    /// repo.json ao lado de um index.min.json (opcional: sem ele, o nome vem do endereço).
    private func legacyRepoJSON(base: String, allowHTTP: Bool) async -> (indexV2: String?, meta: ExtensionIndexDecoder.LegacyRepoMeta?)? {
        guard let downloaded = try? await download(base + "/repo.json", allowHTTP: allowHTTP),
              let detected = try? ExtensionIndexDecoder.detect(downloaded.data, maxDecompressed: limits.maxDecompressedBytes),
              let repo = try? ExtensionIndexDecoder.decodeLegacyRepo(detected.1) else { return nil }
        let next = repo.indexV2.flatMap { ExtensionIndexDecoder.resolve($0, against: downloaded.finalURL) }
        return (next, repo.meta)
    }

    /// Campo 102 (extensionListUrl): a lista fica em outro arquivo.
    private func loadSeparateList(_ index: inout ExtensionStoreIndex, base: URL, allowHTTP: Bool, hopsLeft: Int) async throws {
        guard index.extensions.isEmpty, let listURL = index.extensionListURL, !listURL.isEmpty else { return }
        guard hopsLeft > 0, let target = ExtensionIndexDecoder.resolve(listURL, against: base) else {
            throw FYError.invalidData("extensionListUrl inválido")
        }
        let (raw, _) = try await download(target, allowHTTP: allowHTTP)
        let (format, data) = try ExtensionIndexDecoder.detect(raw, maxDecompressed: limits.maxDecompressedBytes)
        if format == .storeJSON {
            let (list, skipped) = try ExtensionIndexDecoder.decodeExtensionListJSON(data)
            index.extensions = list
            index.skippedEntries += skipped
        } else {
            index.extensions = try ExtensionIndexDecoder.decodeExtensionList(data)
        }
    }

    static func sizeLabel(_ bytes: Int) -> String {
        bytes >= 1024 * 1024 ? "\(bytes / 1024 / 1024) MB" : "\(max(1, bytes / 1024)) KB"
    }

    /// Pasta que contém o arquivo (sem barra final, sem consulta).
    static func folder(of url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: true) ?? URLComponents()
        comps.query = nil
        comps.fragment = nil
        var path = comps.path
        if let slash = path.lastIndex(of: "/") { path = String(path[..<slash]) }
        comps.path = path
        return comps.string ?? url.deletingLastPathComponent().absoluteString
    }

    // MARK: Cache

    /// Grava um índice já validado (ex.: o que foi conferido em "Validar").
    public func save(_ snapshot: CatalogSnapshot, for key: String) throws {
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot.index).write(to: indexFile(key), options: .atomic)
        try JSONEncoder().encode(Meta(sourceURL: snapshot.sourceURL, fetchedAt: snapshot.fetchedAt))
            .write(to: metaFile(key), options: .atomic)
        try? fm.removeItem(at: legacyCacheFile(key))
        try? fm.removeItem(at: legacyMetaFile(key))
    }

    /// Lê o último índice salvo de um repositório, sem rede.
    public func loadCache(for urlString: String) throws -> CatalogSnapshot {
        if let data = try? Data(contentsOf: indexFile(urlString)) {
            let index = try JSONDecoder().decode(ExtensionStoreIndex.self, from: data)
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaFile(urlString)))
            return CatalogSnapshot(index: index, sourceURL: meta.sourceURL, fetchedAt: meta.fetchedAt, isFromCache: true,
                                   networkError: nil)
        }
        let raw = try Data(contentsOf: legacyCacheFile(urlString))
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: legacyMetaFile(urlString)))
        let index = try ExtensionIndexDecoder.decodeStore(raw)
        return CatalogSnapshot(index: index, sourceURL: meta.sourceURL, fetchedAt: meta.fetchedAt, isFromCache: true,
                               networkError: nil)
    }

    /// Apaga o cache de um repositório removido.
    public func removeCache(for urlString: String) {
        for file in [indexFile(urlString), metaFile(urlString), legacyCacheFile(urlString), legacyMetaFile(urlString)] {
            try? fm.removeItem(at: file)
        }
    }
}

/// Resultado do catálogo de um repositório (ou o erro, isolado).
public struct RepositoryCatalog: Sendable, Identifiable {
    public let indexURL: String
    public let snapshot: CatalogSnapshot?
    /// Erro da última tentativa de atualização (mesmo quando há cópia em cache).
    public let error: String?
    public var id: String { indexURL }

    public init(indexURL: String, snapshot: CatalogSnapshot?, error: String?) {
        self.indexURL = indexURL
        self.snapshot = snapshot
        self.error = error
    }

    /// O repositório não respondeu na última atualização.
    public var isUnavailable: Bool { error != nil }

    public var repository: ExtensionRepository {
        if let s = snapshot { return ExtensionRepository(indexURL: indexURL, index: s.index) }
        return ExtensionRepository(indexURL: indexURL, name: RepositoryURL.displayName(indexURL))
    }
}
