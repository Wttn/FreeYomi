import Foundation
import FYCore
import FYDomain

/// Fonte "Arquivos locais": títulos importados pelo usuário (CBZ/ZIP/EPUB/pastas).
/// Funciona 100% offline.
public struct LocalSource: MangaSource {
    public let id: SourceID = .local
    public let name = "Arquivos locais"
    public let language = "all"
    public let kind: SourceKind = .localFiles
    public var supportsLatest: Bool { true }

    public let store: LocalLibraryStore

    public init(store: LocalLibraryStore) {
        self.store = store
    }

    /// URL simbólica da capa, resolvida pelo app contra `store.root`.
    public static func coverURL(relativePath: String) -> String { "freeyomi-local://\(relativePath)" }

    /// Extrai o caminho relativo de uma URL de capa local.
    public static func relativePath(fromCoverURL url: String) -> String? {
        let prefix = "freeyomi-local://"
        guard url.hasPrefix(prefix) else { return nil }
        return PathSanitizer.safeRelativePath(String(url.dropFirst(prefix.count)))
    }

    func toSourceManga(_ m: LocalManifest) -> SourceManga {
        SourceManga(key: m.id, title: m.title, author: m.author, summary: m.summary ?? "Importado de \(m.originalName)",
                    genres: ["Arquivo local"], status: .unknown,
                    coverURL: m.coverPath.map(Self.coverURL(relativePath:)))
    }

    public func popular(page: Int) async throws -> MangaListPage {
        MangaListPage(items: page <= 1 ? store.all().map(toSourceManga) : [], hasNextPage: false)
    }

    public func latest(page: Int) async throws -> MangaListPage {
        let items = store.all().sorted { $0.importedAt > $1.importedAt }.map(toSourceManga)
        return MangaListPage(items: page <= 1 ? items : [], hasNextPage: false)
    }

    public func search(query: String, page: Int) async throws -> MangaListPage {
        let q = query.trimmingCharacters(in: .whitespaces)
        let items = store.all().filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }.map(toSourceManga)
        return MangaListPage(items: page <= 1 ? items : [], hasNextPage: false)
    }

    private func manifest(_ key: String) throws -> LocalManifest {
        guard let m = store.manifest(id: key) else {
            throw FYError.notFound("os arquivos deste título foram removidos")
        }
        return m
    }

    public func details(for manga: SourceManga) async throws -> SourceManga {
        toSourceManga(try manifest(manga.key))
    }

    /// Capítulos na ordem da fonte: mais recente (último) primeiro, como nas demais fontes.
    public func chapters(for manga: SourceManga) async throws -> [SourceChapter] {
        let m = try manifest(manga.key)
        return m.chapters.reversed().map {
            SourceChapter(key: "\(m.id)/\($0.key)", name: $0.name, number: $0.number, scanlator: nil,
                          uploadDate: m.importedAt)
        }
    }

    public func pages(mangaKey: String, chapterKey: String) async throws -> [Page] {
        let m = try manifest(mangaKey)
        let local = chapterKey.split(separator: "/").last.map(String.init) ?? chapterKey
        guard let chapter = m.chapters.first(where: { $0.key == local }) else {
            throw FYError.notFound("capítulo \(chapterKey)")
        }
        return chapter.pages.enumerated().map { i, path in
            Page(index: i, image: .file(relativePath: "\(m.id)/\(path)"))
        }
    }
}
