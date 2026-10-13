import Foundation
import FYCore
import FYDomain

/// Fonte nativa do MangaDex (https://api.mangadex.org), sem servidor intermediário.
///
/// Regras da API respeitadas (api.mangadex.org/docs, consultado em 13/10/2026):
/// - crédito ao MangaDex e aos grupos de tradução (exibidos em cada capítulo);
/// - sem anúncios nem serviços pagos (o FreeYomi é gratuito);
/// - User-Agent real e no máximo ~5 req/s (usamos 4/s) e 40/min em `/at-home/server`;
/// - imagens via `/at-home/server/{id}` (`baseUrl` válido por ~15 min), sem
///   cabeçalho de autenticação; relatório para nós MangaDex@Home (`api.mangadex.network/report`).
public struct MangaDexSource: MangaSource {
    public let id: SourceID = "mangadex"
    public let name = "MangaDex"
    public let kind: SourceKind = .online
    public var supportsLatest: Bool { true }
    /// Idioma das traduções (ex.: "pt-br", "en").
    public let language: String
    public let includeAdult: Bool
    public let dataSaver: Bool
    let http: HTTPClient
    let limiter: RateLimiter
    let atHomeLimiter: RateLimiter

    static let api = "https://api.mangadex.org"
    static let pageSize = 30

    public init(language: String = "pt-br", includeAdult: Bool = false, dataSaver: Bool = false,
                http: HTTPClient = URLSessionHTTPClient(),
                limiter: RateLimiter = RateLimiter(requestsPerSecond: 4),
                atHomeLimiter: RateLimiter = RateLimiter(requestsPerSecond: 40.0 / 60.0)) {
        self.language = language.lowercased()
        self.includeAdult = includeAdult
        self.dataSaver = dataSaver
        self.http = http
        self.limiter = limiter
        self.atHomeLimiter = atHomeLimiter
    }

    // MARK: Modelos JSON

    struct Collection<T: Decodable>: Decodable { let data: [T]; let limit: Int?; let offset: Int?; let total: Int? }
    struct Single<T: Decodable>: Decodable { let data: T }

    struct MangaEntity: Decodable {
        let id: String
        let attributes: Attributes
        let relationships: [Relationship]?

        struct Attributes: Decodable {
            let title: [String: String]
            let altTitles: [[String: String]]?
            let description: [String: String]?
            let status: String?
            let tags: [Tag]?
        }
        struct Tag: Decodable {
            let attributes: TagAttributes
            struct TagAttributes: Decodable { let name: [String: String] }
        }
    }

    struct Relationship: Decodable {
        let id: String?
        let type: String
        let attributes: RelAttributes?
        struct RelAttributes: Decodable { let fileName: String?; let name: String? }
    }

    struct ChapterEntity: Decodable {
        let id: String
        let attributes: Attributes
        let relationships: [Relationship]?
        struct Attributes: Decodable {
            let volume: String?
            let chapter: String?
            let title: String?
            let translatedLanguage: String?
            let externalUrl: String?
            let publishAt: String?
            let pages: Int?
        }
    }

    struct AtHome: Decodable {
        let baseUrl: String
        let chapter: Files
        struct Files: Decodable { let hash: String; let data: [String]; let dataSaver: [String] }
    }

    // MARK: Requisições

    private var ratings: [URLQueryItem] {
        var r = ["safe", "suggestive"]
        if includeAdult { r.append("erotica") }
        return r.map { URLQueryItem(name: "contentRating[]", value: $0) }
    }

    private func request<T: Decodable>(_ path: String, _ query: [URLQueryItem], as: T.Type,
                                       limiter: RateLimiter? = nil) async throws -> T {
        try await (limiter ?? self.limiter).wait()
        var comps = URLComponents(string: Self.api + path)!
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw FYError.invalidData("URL inválida") }
        let response = try await http.get(url, headers: [:])
        switch response.statusCode {
        case 200..<300: break
        case 429: throw FYError.network("o MangaDex limitou as requisições; aguarde alguns segundos")
        case 404: throw FYError.notFound("conteúdo no MangaDex")
        default: throw FYError.httpStatus(response.statusCode, url: Redactor.redact(url))
        }
        do {
            return try JSONDecoder().decode(T.self, from: response.body)
        } catch {
            throw FYError.invalidData("resposta inesperada do MangaDex")
        }
    }

    // MARK: Conversão

    func pickTitle(_ m: MangaEntity) -> String {
        let t = m.attributes.title
        if let v = t[language] ?? m.attributes.altTitles?.first(where: { $0[language] != nil })?[language] { return v }
        return t["en"] ?? t["ja-ro"] ?? t.values.first ?? "Sem título"
    }

    func map(_ m: MangaEntity) -> SourceManga {
        let rels = m.relationships ?? []
        let cover = rels.first { $0.type == "cover_art" }?.attributes?.fileName
        let authors = rels.filter { $0.type == "author" }.compactMap { $0.attributes?.name }
        let artists = rels.filter { $0.type == "artist" }.compactMap { $0.attributes?.name }
        let desc = m.attributes.description
        let status: PublicationStatus
        switch m.attributes.status {
        case "ongoing": status = .ongoing
        case "completed": status = .completed
        case "hiatus": status = .hiatus
        case "cancelled": status = .cancelled
        default: status = .unknown
        }
        return SourceManga(
            key: m.id, title: pickTitle(m),
            author: authors.isEmpty ? nil : authors.joined(separator: ", "),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", "),
            summary: desc?[language] ?? desc?["en"] ?? desc?.values.first,
            genres: (m.attributes.tags ?? []).compactMap { $0.attributes.name["en"] },
            status: status,
            coverURL: cover.map { "https://uploads.mangadex.org/covers/\(m.id)/\($0).256.jpg" })
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func map(_ c: ChapterEntity) -> SourceChapter {
        let a = c.attributes
        var name = ""
        if let v = a.volume, !v.isEmpty { name += "Vol. \(v) " }
        if let ch = a.chapter, !ch.isEmpty { name += "Cap. \(ch)" } else { name += "Oneshot" }
        if let t = a.title, !t.isEmpty { name += " — \(t)" }
        let groups = (c.relationships ?? []).filter { $0.type == "scanlation_group" }.compactMap { $0.attributes?.name }
        return SourceChapter(key: c.id, name: name, number: a.chapter.flatMap(Double.init) ?? -1,
                             scanlator: groups.isEmpty ? "Sem grupo" : groups.joined(separator: " & "),
                             uploadDate: a.publishAt.flatMap { Self.isoFormatter.date(from: $0) })
    }

    // MARK: MangaSource

    private func listQuery(page: Int, order: String) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(Self.pageSize)),
         URLQueryItem(name: "offset", value: String(max(0, page - 1) * Self.pageSize)),
         URLQueryItem(name: "includes[]", value: "cover_art"),
         URLQueryItem(name: "includes[]", value: "author"),
         URLQueryItem(name: "availableTranslatedLanguage[]", value: language),
         URLQueryItem(name: "hasAvailableChapters", value: "true"),
         URLQueryItem(name: "order[\(order)]", value: "desc")] + ratings
    }

    private func page(_ c: Collection<MangaEntity>, page: Int) -> MangaListPage {
        let offset = c.offset ?? (page - 1) * Self.pageSize
        let total = c.total ?? 0
        // A API recusa offset + limit > 10 000.
        let hasNext = offset + c.data.count < min(total, 10_000 - Self.pageSize)
        return MangaListPage(items: c.data.map(map), hasNextPage: hasNext)
    }

    public func popular(page p: Int) async throws -> MangaListPage {
        page(try await request("/manga", listQuery(page: p, order: "followedCount"), as: Collection<MangaEntity>.self), page: p)
    }

    public func latest(page p: Int) async throws -> MangaListPage {
        page(try await request("/manga", listQuery(page: p, order: "latestUploadedChapter"), as: Collection<MangaEntity>.self), page: p)
    }

    public func search(query: String, page p: Int) async throws -> MangaListPage {
        var q = listQuery(page: p, order: "relevance")
        q.append(URLQueryItem(name: "title", value: query))
        return page(try await request("/manga", q, as: Collection<MangaEntity>.self), page: p)
    }

    public func details(for manga: SourceManga) async throws -> SourceManga {
        let q = [URLQueryItem(name: "includes[]", value: "cover_art"), URLQueryItem(name: "includes[]", value: "author"),
                 URLQueryItem(name: "includes[]", value: "artist")]
        return map(try await request("/manga/\(manga.key)", q, as: Single<MangaEntity>.self).data)
    }

    /// Todos os capítulos legíveis no app (capítulos só externos, como os da
    /// MANGA Plus, são omitidos), do mais recente para o mais antigo.
    public func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        var all: [ChapterEntity] = []
        var offset = 0
        let limit = 500
        while true {
            let q = [URLQueryItem(name: "translatedLanguage[]", value: language),
                     URLQueryItem(name: "limit", value: String(limit)),
                     URLQueryItem(name: "offset", value: String(offset)),
                     URLQueryItem(name: "order[volume]", value: "desc"),
                     URLQueryItem(name: "order[chapter]", value: "desc"),
                     URLQueryItem(name: "includes[]", value: "scanlation_group")]
                + ["safe", "suggestive", "erotica", "pornographic"].map { URLQueryItem(name: "contentRating[]", value: $0) }
            let c = try await request("/manga/\(manga.key)/feed", q, as: Collection<ChapterEntity>.self)
            all += c.data
            offset += c.data.count
            if c.data.isEmpty || offset >= (c.total ?? 0) || offset + limit > 10_000 { break }
        }
        return all
            .filter { ($0.attributes.externalUrl ?? "").isEmpty && ($0.attributes.pages ?? 1) > 0 }
            .map(map)
    }

    public func pages(mangaKey: String, chapterKey: String) async throws -> [Page] {
        let home = try await request("/at-home/server/\(chapterKey)", [], as: AtHome.self, limiter: atHomeLimiter)
        let files = dataSaver ? home.chapter.dataSaver : home.chapter.data
        let quality = dataSaver ? "data-saver" : "data"
        guard !files.isEmpty else { throw FYError.invalidData("capítulo sem páginas no MangaDex") }
        let report = !home.baseUrl.contains("mangadex.org")
        return files.enumerated().map { i, file in
            Page(index: i, image: .remote(url: "\(home.baseUrl)/\(quality)/\(home.chapter.hash)/\(file)",
                                          headers: report ? [MangaDexReporter.marker: "1"] : [:]))
        }
    }
}

/// Relatório exigido pela rede MangaDex@Home para cada imagem baixada de nós
/// que não são `mangadex.org`.
public enum MangaDexReporter {
    /// Cabeçalho interno (nunca enviado) que marca imagens a relatar.
    public static let marker = "X-FreeYomi-MangaDexReport"

    public static func report(url: String, success: Bool, cached: Bool, bytes: Int, durationMs: Int,
                              http: HTTPClient) async {
        guard let endpoint = URL(string: "https://api.mangadex.network/report"),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "url": url, "success": success, "cached": cached, "bytes": bytes, "duration": durationMs,
              ]) else { return }
        _ = try? await http.post(endpoint, json: body, headers: [:])
    }
}
