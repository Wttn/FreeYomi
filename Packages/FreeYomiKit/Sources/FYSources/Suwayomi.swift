import Foundation
import FYCore
import FYDomain
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cliente do Suwayomi-Server (https://github.com/Suwayomi/Suwayomi-Server, MPL-2.0).
//
// O servidor roda no computador/NAS do usuário e executa as extensões do
// catálogo (Keiyoushi etc.) numa JVM. O FreeYomi só conversa com a API REST
// v1 do servidor: nenhum código de extensão roda no iPhone.
//
// Endpoints usados (conferidos em server/.../manga/MangaAPI.kt e GlobalAPI.kt,
// commit 635751a de 13/10/2026):
//   GET  /api/v1/settings/about
//   GET  /api/v1/extension/list
//   GET  /api/v1/extension/install/{pkgName}   · update/{pkgName} · uninstall/{pkgName}
//   GET  /api/v1/source/list
//   GET  /api/v1/source/{sourceId}/popular/{pageNum} · latest/{pageNum}
//   GET  /api/v1/source/{sourceId}/search?searchTerm=&pageNum=
//   GET  /api/v1/manga/{mangaId}?onlineFetch=
//   GET  /api/v1/manga/{mangaId}/chapters?onlineFetch=
//   GET  /api/v1/manga/{mangaId}/chapter/{chapterIndex}          (busca as páginas, devolve pageCount)
//   GET  /api/v1/manga/{mangaId}/chapter/{chapterIndex}/page/{i} (imagem)
//   GET  /api/v1/manga/{mangaId}/thumbnail
//   POST /api/graphql  query extensionStores · query extensions{pkgName storeIndexUrl}
//                      mutation addExtensionStore / removeExtensionStore(input: {indexUrl})

/// Configuração de conexão (a senha vem do Keychain do app, nunca do banco).
public struct SuwayomiConfig: Sendable, Equatable {
    public var baseURL: URL
    public var username: String?
    public var password: String?
    public var allowInsecureHTTP: Bool

    public init(baseURL: URL, username: String? = nil, password: String? = nil, allowInsecureHTTP: Bool = false) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    /// Normaliza o endereço digitado pelo usuário ("192.168.0.10:4567" → "http://192.168.0.10:4567").
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard var comps = URLComponents(string: text), let host = comps.host, !host.isEmpty else { return nil }
        guard comps.scheme == "http" || comps.scheme == "https" else { return nil }
        comps.query = nil
        comps.fragment = nil
        comps.user = nil
        comps.password = nil
        return comps.url
    }

    public var policy: RequestPolicy { .personalServer(base: baseURL, allowHTTP: allowInsecureHTTP) }

    public var authHeaders: [String: String] {
        guard let u = username, !u.isEmpty else { return [:] }
        return URLSessionHTTPClient.basicAuth(user: u, password: password ?? "")
    }
}

// MARK: - Modelos (espelham os data classes do servidor; campos extras são ignorados)

public struct SuwayomiAbout: Decodable, Sendable { public let name: String; public let version: String }

public struct SuwayomiExtension: Decodable, Sendable, Identifiable, Hashable {
    public let pkgName: String
    public let name: String
    public let lang: String
    public let versionName: String
    public let iconUrl: String
    public let isNsfw: Bool
    public let installed: Bool
    public let hasUpdate: Bool
    public let obsolete: Bool
    public let repo: String?
    public var id: String { pkgName }
}

public struct SuwayomiSourceInfo: Decodable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let lang: String
    public let displayName: String
    public let iconUrl: String
    public let supportsLatest: Bool
    public let isNsfw: Bool
}

public struct SuwayomiManga: Decodable, Sendable {
    public let id: Int
    public let sourceId: String
    public let title: String
    public let thumbnailUrl: String?
    public let author: String?
    public let artist: String?
    public let description: String?
    public let genre: [String]?
    public let status: String?
}

public struct SuwayomiMangaPage: Decodable, Sendable {
    public let mangaList: [SuwayomiManga]
    public let hasNextPage: Bool
}

public struct SuwayomiChapter: Decodable, Sendable {
    public let id: Int
    public let url: String
    public let name: String
    public let uploadDate: Int64
    public let chapterNumber: Double
    public let scanlator: String?
    public let mangaId: Int
    /// Posição do capítulo (começa em 1).
    public let index: Int
    public let pageCount: Int?
}

// MARK: - Cliente

public struct SuwayomiClient: Sendable {
    public let config: SuwayomiConfig
    let http: HTTPClient

    public init(config: SuwayomiConfig, http: HTTPClient? = nil) {
        self.config = config
        self.http = http ?? URLSessionHTTPClient(policy: config.policy, defaultHeaders: config.authHeaders)
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// URL absoluta para caminhos relativos devolvidos pelo servidor (ex.: "/api/v1/manga/1/thumbnail").
    public func absolute(_ pathOrURL: String) -> String {
        if pathOrURL.hasPrefix("http://") || pathOrURL.hasPrefix("https://") { return pathOrURL }
        return url(pathOrURL.hasPrefix("/") ? pathOrURL : "/" + pathOrURL).absoluteString
    }

    private func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let response = try await http.get(url(path, query: query), headers: [:])
        try Self.check(response, path: path)
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await getData(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FYError.invalidData("resposta inesperada do servidor em \(path) — a versão do Suwayomi é compatível?")
        }
    }

    static func check(_ r: HTTPResponse, path: String) throws {
        switch r.statusCode {
        case 200..<400: return
        case 401, 403: throw FYError.network("o servidor recusou o acesso — confira usuário e senha")
        case 404: throw FYError.notFound("recurso no servidor (\(path))")
        default:
            let detail = String(data: r.body.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw FYError.network("o servidor respondeu \(r.statusCode)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }

    // Servidor
    public func about() async throws -> SuwayomiAbout { try await decode(SuwayomiAbout.self, "/api/v1/settings/about") }

    // Extensões
    public func extensions() async throws -> [SuwayomiExtension] {
        try await decode([SuwayomiExtension].self, "/api/v1/extension/list")
    }
    public func install(_ pkg: String) async throws { _ = try await getData("/api/v1/extension/install/\(Self.escape(pkg))") }
    public func update(_ pkg: String) async throws { _ = try await getData("/api/v1/extension/update/\(Self.escape(pkg))") }
    public func uninstall(_ pkg: String) async throws { _ = try await getData("/api/v1/extension/uninstall/\(Self.escape(pkg))") }

    // Repositórios de extensões (GraphQL; conferido em graphql/queries/ExtensionStoreQuery.kt
    // e graphql/mutations/ExtensionStoreMutation.kt, commit 635751a)

    static let storeFields = "name badgeLabel signingKey contactWebsite contactDiscord indexUrl extensions { totalCount }"

    /// Executa uma operação GraphQL e devolve o objeto `data`.
    func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let response = try await http.post(url("/api/graphql"), json: body, headers: [:])
        try Self.check(response, path: "/api/graphql")
        guard let obj = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw FYError.invalidData("resposta GraphQL inválida do servidor")
        }
        if let errors = obj["errors"] as? [[String: Any]], let first = errors.first {
            let message = (first["message"] as? String ?? "erro desconhecido")
            throw FYError.network("o servidor recusou a operação: \(message.prefix(200))")
        }
        return obj["data"] as? [String: Any] ?? [:]
    }

    static func repository(_ o: [String: Any]) -> ExtensionRepository? {
        guard let indexUrl = o["indexUrl"] as? String else { return nil }
        let count = (o["extensions"] as? [String: Any])?["totalCount"] as? Int
        func opt(_ k: String) -> String? { (o[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return ExtensionRepository(indexURL: indexUrl, name: opt("name") ?? RepositoryURL.displayName(indexUrl),
                                   badgeLabel: o["badgeLabel"] as? String ?? "", website: opt("contactWebsite"),
                                   discord: opt("contactDiscord"), signingKey: opt("signingKey"), extensionCount: count)
    }

    /// Repositórios configurados no servidor.
    public func extensionStores() async throws -> [ExtensionRepository] {
        let data = try await graphQL("query { extensionStores { nodes { \(Self.storeFields) } } }")
        let nodes = (data["extensionStores"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap(Self.repository)
    }

    /// Adiciona um repositório ao servidor (GraphQL `addExtensionStore`). O servidor
    /// baixa e valida o índice; adicionar de novo o mesmo endereço só o atualiza.
    @discardableResult
    public func addExtensionStore(indexURL: String) async throws -> ExtensionRepository? {
        let q = "mutation($url: String!) { addExtensionStore(input: {indexUrl: $url}) { extensionStore { \(Self.storeFields) } } }"
        let data = try await graphQL(q, variables: ["url": indexURL])
        let store = ((data["addExtensionStore"] as? [String: Any])?["extensionStore"]) as? [String: Any]
        return store.flatMap(Self.repository)
    }

    /// Remove um repositório do servidor (GraphQL `removeExtensionStore`). Use o
    /// `indexUrl` exatamente como o servidor o guardou.
    public func removeExtensionStore(indexURL: String) async throws {
        let q = "mutation($url: String!) { removeExtensionStore(input: {indexUrl: $url}) { extensionStore { indexUrl } } }"
        _ = try await graphQL(q, variables: ["url": indexURL])
    }

    /// Mapa pacote → repositório de origem (`storeIndexUrl`), para o selo de cada extensão.
    public func extensionStoreIndex() async throws -> [String: String] {
        let data = try await graphQL("query { extensions { nodes { pkgName storeIndexUrl } } }")
        let nodes = (data["extensions"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        var map: [String: String] = [:]
        for n in nodes {
            if let pkg = n["pkgName"] as? String, let store = n["storeIndexUrl"] as? String { map[pkg] = store }
        }
        return map
    }

    // Fontes
    public func sources() async throws -> [SuwayomiSourceInfo] {
        try await decode([SuwayomiSourceInfo].self, "/api/v1/source/list").filter { $0.id != "0" } // 0 = fonte local do servidor
    }
    public func popular(source: String, page: Int) async throws -> SuwayomiMangaPage {
        try await decode(SuwayomiMangaPage.self, "/api/v1/source/\(source)/popular/\(page)")
    }
    public func latest(source: String, page: Int) async throws -> SuwayomiMangaPage {
        try await decode(SuwayomiMangaPage.self, "/api/v1/source/\(source)/latest/\(page)")
    }
    public func search(source: String, query: String, page: Int) async throws -> SuwayomiMangaPage {
        try await decode(SuwayomiMangaPage.self, "/api/v1/source/\(source)/search",
                         query: [URLQueryItem(name: "searchTerm", value: query), URLQueryItem(name: "pageNum", value: String(page))])
    }

    // Títulos
    public func manga(_ id: Int, online: Bool) async throws -> SuwayomiManga {
        try await decode(SuwayomiManga.self, "/api/v1/manga/\(id)", query: [URLQueryItem(name: "onlineFetch", value: String(online))])
    }
    public func chapters(_ mangaId: Int, online: Bool) async throws -> [SuwayomiChapter] {
        try await decode([SuwayomiChapter].self, "/api/v1/manga/\(mangaId)/chapters",
                         query: [URLQueryItem(name: "onlineFetch", value: String(online))])
    }
    public func chapter(_ mangaId: Int, index: Int) async throws -> SuwayomiChapter {
        try await decode(SuwayomiChapter.self, "/api/v1/manga/\(mangaId)/chapter/\(index)")
    }
    public func pageURL(_ mangaId: Int, index: Int, page: Int) -> String {
        url("/api/v1/manga/\(mangaId)/chapter/\(index)/page/\(page)").absoluteString
    }

    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }
}

// MARK: - Fonte do servidor como MangaSource

/// Uma fonte (extensão instalada) do Suwayomi-Server, exposta ao app como
/// qualquer outra fonte. ID estável: "suwayomi:<id da fonte no servidor>".
public struct SuwayomiSource: MangaSource {
    public let id: SourceID
    public let name: String
    public let language: String
    public let kind: SourceKind = .personalServer
    public let supportsLatest: Bool
    public let isNSFW: Bool
    public let remoteId: String
    let client: SuwayomiClient

    public static let prefix = "suwayomi:"

    public init(info: SuwayomiSourceInfo, client: SuwayomiClient) {
        id = SourceID(Self.prefix + info.id)
        name = info.displayName.isEmpty ? info.name : info.displayName
        language = Self.normalizeLanguage(info.lang)
        supportsLatest = info.supportsLatest
        isNSFW = info.isNsfw
        remoteId = info.id
        self.client = client
    }

    /// Converte os códigos das extensões ("pt-BR", "all", "localsourcelang") para BCP-47 simples.
    static func normalizeLanguage(_ lang: String) -> String {
        switch lang {
        case "", "localsourcelang": return "all"
        default: return lang
        }
    }

    func map(_ m: SuwayomiManga) -> SourceManga {
        SourceManga(key: String(m.id), title: m.title, author: m.author, artist: m.artist, summary: m.description,
                    genres: m.genre ?? [], status: Self.status(m.status),
                    coverURL: m.thumbnailUrl.map(client.absolute) ?? client.absolute("/api/v1/manga/\(m.id)/thumbnail"))
    }

    static func status(_ s: String?) -> PublicationStatus {
        switch s?.uppercased() {
        case "ONGOING": return .ongoing
        case "COMPLETED": return .completed
        case "LICENSED": return .licensed
        case "PUBLISHING_FINISHED": return .publishingFinished
        case "CANCELLED": return .cancelled
        case "ON_HIATUS": return .hiatus
        default: return .unknown
        }
    }

    private func list(_ page: SuwayomiMangaPage) -> MangaListPage {
        MangaListPage(items: page.mangaList.map(map), hasNextPage: page.hasNextPage)
    }

    public func popular(page: Int) async throws -> MangaListPage { list(try await client.popular(source: remoteId, page: page)) }
    public func latest(page: Int) async throws -> MangaListPage { list(try await client.latest(source: remoteId, page: page)) }
    public func search(query: String, page: Int) async throws -> MangaListPage {
        list(try await client.search(source: remoteId, query: query, page: page))
    }

    private func mangaId(_ key: String) throws -> Int {
        guard let id = Int(key) else { throw FYError.invalidData("identificador de título inválido") }
        return id
    }

    public func details(for manga: SourceManga) async throws -> SourceManga {
        map(try await client.manga(try mangaId(manga.key), online: true))
    }

    /// Capítulos do mais recente para o mais antigo. A chave usa a URL do
    /// capítulo na fonte (estável), não o índice (que muda quando saem capítulos novos).
    public func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        let id = try mangaId(manga.key)
        return try await client.chapters(id, online: true)
            .sorted { $0.index > $1.index }
            .map { c in
                SourceChapter(key: "\(id)|\(c.url)", name: c.name, number: c.chapterNumber >= 0 ? c.chapterNumber : -1,
                              scanlator: c.scanlator?.isEmpty == false ? c.scanlator : nil,
                              uploadDate: c.uploadDate > 0 ? Date(timeIntervalSince1970: Double(c.uploadDate) / 1000) : nil)
            }
    }

    public func pages(mangaKey: String, chapterKey: String) async throws -> [Page] {
        let id = try mangaId(mangaKey)
        let chapterURL = chapterKey.split(separator: "|", maxSplits: 1).last.map(String.init) ?? chapterKey
        var list = try await client.chapters(id, online: false)
        if !list.contains(where: { $0.url == chapterURL }) { list = try await client.chapters(id, online: true) }
        guard let found = list.first(where: { $0.url == chapterURL }) else {
            throw FYError.notFound("capítulo no servidor (talvez removido pela fonte)")
        }
        let chapter = try await client.chapter(id, index: found.index) // faz o servidor buscar a lista de páginas
        let count = chapter.pageCount ?? 0
        guard count > 0 else { throw FYError.invalidData("a fonte não retornou páginas para este capítulo") }
        return (0..<count).map { Page(index: $0, image: .remote(url: client.pageURL(id, index: found.index, page: $0), headers: [:])) }
    }
}
