import Foundation
import FYCore
import FYDomain

/// Fonte de demonstração com dados 100% locais e fictícios.
///
/// Os títulos, autores e páginas são inventados pelo projeto e claramente
/// rotulados como "Demonstração". As páginas são desenhadas pelo próprio app
/// (`ImageRef.demo`), sem imagens de terceiros.
public struct DemoSource: MangaSource {
    public let id: SourceID = .demo
    public let name = "Demonstração (local)"
    public let language = "pt-BR"
    public let kind: SourceKind = .demo
    public var supportsLatest: Bool { true }

    /// Latência artificial opcional, útil para testar estados de carregamento.
    public var simulatedDelay: UInt64 = 0

    public init(simulatedDelay: UInt64 = 0) {
        self.simulatedDelay = simulatedDelay
    }

    struct Entry {
        let key: String
        let title: String
        let author: String
        let summary: String
        let genres: [String]
        let status: PublicationStatus
        let chapterCount: Int
        let pagesPerChapter: Int
        let aspectRatio: Double // altura / largura
        let hue: Int
    }

    static let catalog: [Entry] = [
        Entry(key: "demo/farol-de-vidro", title: "Demonstração · O Farol de Vidro",
              author: "Equipe FreeYomi (fictício)",
              summary: "Título fictício usado para demonstrar a leitura paginada da direita para a esquerda.",
              genres: ["Demonstração", "Aventura"], status: .ongoing, chapterCount: 12, pagesPerChapter: 18,
              aspectRatio: 1.42, hue: 210),
        Entry(key: "demo/cidade-das-mares", title: "Demonstração · Cidade das Marés",
              author: "Equipe FreeYomi (fictício)",
              summary: "Título fictício concluído, usado para testar filtros e o status \"Concluído\".",
              genres: ["Demonstração", "Mistério"], status: .completed, chapterCount: 6, pagesPerChapter: 14,
              aspectRatio: 1.42, hue: 160),
        Entry(key: "demo/rolagem-infinita", title: "Demonstração · Rolagem Infinita",
              author: "Equipe FreeYomi (fictício)",
              summary: "Webtoon fictício com páginas longas, para testar a rolagem vertical contínua.",
              genres: ["Demonstração", "Webtoon"], status: .ongoing, chapterCount: 8, pagesPerChapter: 10,
              aspectRatio: 3.2, hue: 300),
        Entry(key: "demo/quadro-a-quadro", title: "Demonstração · Quadro a Quadro",
              author: "Equipe FreeYomi (fictício)",
              summary: "Quadrinho fictício da esquerda para a direita.",
              genres: ["Demonstração", "Comédia"], status: .hiatus, chapterCount: 4, pagesPerChapter: 22,
              aspectRatio: 1.5, hue: 30),
    ]

    static func entry(_ key: String) -> Entry? { catalog.first { $0.key == key } }

    /// URL simbólica de capa, interpretada pelo app para desenhar a capa localmente.
    public static func coverURL(for key: String) -> String { "freeyomi-demo://cover/\(key)" }

    func toSourceManga(_ e: Entry) -> SourceManga {
        SourceManga(key: e.key, title: e.title, author: e.author, artist: e.author, summary: e.summary,
                    genres: e.genres, status: e.status, coverURL: Self.coverURL(for: e.key))
    }

    private func wait() async throws {
        if simulatedDelay > 0 { try await Task.sleep(nanoseconds: simulatedDelay) }
        if Task.isCancelled { throw FYError.cancelled }
    }

    public func popular(page: Int) async throws -> MangaListPage {
        try await wait()
        return MangaListPage(items: page <= 1 ? Self.catalog.map(toSourceManga) : [], hasNextPage: false)
    }

    public func latest(page: Int) async throws -> MangaListPage {
        try await wait()
        return MangaListPage(items: page <= 1 ? Self.catalog.reversed().map(toSourceManga) : [], hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> MangaListPage {
        try await wait()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let items = Self.catalog.filter { q.isEmpty || $0.title.lowercased().contains(q) }.map(toSourceManga)
        return MangaListPage(items: page <= 1 ? items : [], hasNextPage: false)
    }

    public func details(for manga: SourceManga) async throws -> SourceManga {
        try await wait()
        guard let e = Self.entry(manga.key) else { throw FYError.notFound(manga.key) }
        return toSourceManga(e)
    }

    public func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        try await wait()
        guard let e = Self.entry(manga.key) else { throw FYError.notFound(manga.key) }
        let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01, datas fictícias estáveis
        // Ordem da fonte: mais recente primeiro (padrão Mihon/Tachiyomi).
        return (1...e.chapterCount).reversed().map { n in
            SourceChapter(key: "\(e.key)/cap-\(n)", name: "Capítulo \(n)", number: Double(n),
                          scanlator: "Demonstração", uploadDate: base.addingTimeInterval(Double(n) * 7 * 86_400))
        }
    }

    public func pages(mangaKey: String, chapterKey: String) async throws -> [Page] {
        try await wait()
        guard let e = Self.entry(mangaKey) else { throw FYError.notFound(mangaKey) }
        guard let n = Int(chapterKey.split(separator: "-").last ?? ""), (1...e.chapterCount).contains(n) else {
            throw FYError.notFound(chapterKey)
        }
        return (0..<e.pagesPerChapter).map { i in
            Page(index: i, image: .demo(seed: e.hue * 1000 + n * 50 + i,
                                        label: "Cap. \(n) · Página \(i + 1) de \(e.pagesPerChapter)",
                                        aspectRatio: e.aspectRatio))
        }
    }

    /// Matiz (0–360) usada pelo app para desenhar capas e páginas fictícias.
    public static func hue(for key: String) -> Int { entry(key)?.hue ?? 0 }
}
