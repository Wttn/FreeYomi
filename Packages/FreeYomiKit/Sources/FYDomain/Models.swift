import Foundation

// MARK: - Identificadores

/// Identificador estável de uma fonte (ex.: "demo", "local", "komga:<uuid>").
///
/// Fontes nativas do FreeYomi usam strings estáveis. IDs numéricos de
/// extensões Android (Int64 do índice Keiyoushi) ficam apenas no catálogo.
public struct SourceID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let demo: SourceID = "demo"
    public static let local: SourceID = "local"
}

/// Chave composta que distingue títulos de fontes diferentes:
/// `(sourceId, key)`, onde `key` é o identificador do título na fonte
/// (normalmente um caminho/URL relativo).
public struct MangaKey: Hashable, Codable, Sendable {
    public let sourceId: SourceID
    public let key: String
    public init(sourceId: SourceID, key: String) {
        self.sourceId = sourceId
        self.key = key
    }
}

// MARK: - Fonte

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    /// Dados locais embutidos, apenas para demonstração.
    case demo
    /// Arquivos importados pelo usuário (CBZ, ZIP, pastas).
    case localFiles
    /// Servidor pessoal (Komga etc.).
    case personalServer
    /// Fonte online com adaptador nativo.
    case online
}

public struct Source: Hashable, Codable, Sendable, Identifiable {
    public var id: SourceID
    public var name: String
    public var language: String
    public var kind: SourceKind
    public var isEnabled: Bool
    public var isPinned: Bool
    public var lastUsedAt: Date?

    public init(id: SourceID, name: String, language: String, kind: SourceKind,
                isEnabled: Bool = true, isPinned: Bool = false, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.kind = kind
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.lastUsedAt = lastUsedAt
    }
}

// MARK: - Título

public enum PublicationStatus: Int, Codable, Sendable, CaseIterable {
    case unknown = 0
    case ongoing = 1
    case completed = 2
    case licensed = 3
    case publishingFinished = 4
    case cancelled = 5
    case hiatus = 6

    public var label: String {
        switch self {
        case .unknown: return "Desconhecido"
        case .ongoing: return "Em andamento"
        case .completed: return "Concluído"
        case .licensed: return "Licenciado"
        case .publishingFinished: return "Publicação finalizada"
        case .cancelled: return "Cancelado"
        case .hiatus: return "Em hiato"
        }
    }
}

public struct Manga: Hashable, Codable, Sendable, Identifiable {
    /// ID local (linha do banco). `0` antes de ser persistido.
    public var id: Int64
    public var sourceId: SourceID
    public var key: String
    public var title: String
    public var author: String?
    public var artist: String?
    public var summary: String?
    public var genres: [String]
    public var status: PublicationStatus
    public var coverURL: String?
    /// Marca dados de demonstração, para que nunca sejam confundidos com conteúdo real.
    public var isDemo: Bool
    public var updatedAt: Date

    public var mangaKey: MangaKey { MangaKey(sourceId: sourceId, key: key) }

    public init(id: Int64 = 0, sourceId: SourceID, key: String, title: String, author: String? = nil,
                artist: String? = nil, summary: String? = nil, genres: [String] = [],
                status: PublicationStatus = .unknown, coverURL: String? = nil, isDemo: Bool = false,
                updatedAt: Date = Date()) {
        self.id = id
        self.sourceId = sourceId
        self.key = key
        self.title = title
        self.author = author
        self.artist = artist
        self.summary = summary
        self.genres = genres
        self.status = status
        self.coverURL = coverURL
        self.isDemo = isDemo
        self.updatedAt = updatedAt
    }
}

// MARK: - Capítulo e página

public struct Chapter: Hashable, Codable, Sendable, Identifiable {
    public var id: Int64
    public var mangaId: Int64
    public var key: String
    public var name: String
    /// Número do capítulo (-1 quando desconhecido).
    public var number: Double
    public var scanlator: String?
    public var uploadDate: Date?
    /// Ordem fornecida pela fonte (0 = mais recente na maioria das fontes).
    public var sourceOrder: Int
    public var isRead: Bool
    public var isBookmarked: Bool
    public var fetchedAt: Date

    public init(id: Int64 = 0, mangaId: Int64, key: String, name: String, number: Double = -1,
                scanlator: String? = nil, uploadDate: Date? = nil, sourceOrder: Int = 0,
                isRead: Bool = false, isBookmarked: Bool = false, fetchedAt: Date = Date()) {
        self.id = id
        self.mangaId = mangaId
        self.key = key
        self.name = name
        self.number = number
        self.scanlator = scanlator
        self.uploadDate = uploadDate
        self.sourceOrder = sourceOrder
        self.isRead = isRead
        self.isBookmarked = isBookmarked
        self.fetchedAt = fetchedAt
    }
}

/// Referência à imagem de uma página.
public enum ImageRef: Hashable, Codable, Sendable {
    /// Imagem remota com cabeçalhos exigidos pela fonte (ex.: Referer).
    case remote(url: String, headers: [String: String])
    /// Arquivo local (capítulo baixado ou importado), caminho relativo à pasta do app.
    case file(relativePath: String)
    /// Página gerada pelo próprio app para a fonte de demonstração.
    case demo(seed: Int, label: String, aspectRatio: Double)
}

public struct Page: Hashable, Codable, Sendable, Identifiable {
    public var index: Int
    public var image: ImageRef
    public var id: Int { index }

    public init(index: Int, image: ImageRef) {
        self.index = index
        self.image = image
    }
}

// MARK: - Biblioteca e categorias

public struct MangaCategory: Hashable, Codable, Sendable, Identifiable {
    public var id: Int64
    public var name: String
    public var order: Int

    public init(id: Int64 = 0, name: String, order: Int = 0) {
        self.id = id
        self.name = name
        self.order = order
    }
}

public struct LibraryEntry: Hashable, Codable, Sendable {
    public var mangaId: Int64
    public var addedAt: Date
    public var categoryIds: [Int64]

    public init(mangaId: Int64, addedAt: Date = Date(), categoryIds: [Int64] = []) {
        self.mangaId = mangaId
        self.addedAt = addedAt
        self.categoryIds = categoryIds
    }
}

/// Linha exibida na Biblioteca (título + dados agregados).
public struct LibraryItem: Hashable, Sendable, Identifiable {
    public var manga: Manga
    public var entry: LibraryEntry
    public var unreadCount: Int
    public var totalChapters: Int
    public var lastReadAt: Date?
    public var lastReadChapterName: String?
    public var id: Int64 { manga.id }

    public init(manga: Manga, entry: LibraryEntry, unreadCount: Int, totalChapters: Int,
                lastReadAt: Date?, lastReadChapterName: String?) {
        self.manga = manga
        self.entry = entry
        self.unreadCount = unreadCount
        self.totalChapters = totalChapters
        self.lastReadAt = lastReadAt
        self.lastReadChapterName = lastReadChapterName
    }
}

// MARK: - Progresso e histórico

public struct ReadingProgress: Hashable, Codable, Sendable {
    public var chapterId: Int64
    public var mangaId: Int64
    /// Página atual (modo paginado) ou página mais visível (modo vertical).
    public var pageIndex: Int
    public var pageCount: Int
    /// Deslocamento dentro da página atual, de 0 a 1 (modo vertical/webtoon).
    public var scrollOffset: Double
    public var isFinished: Bool
    public var updatedAt: Date

    public init(chapterId: Int64, mangaId: Int64, pageIndex: Int, pageCount: Int, scrollOffset: Double = 0,
                isFinished: Bool = false, updatedAt: Date = Date()) {
        self.chapterId = chapterId
        self.mangaId = mangaId
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.scrollOffset = min(max(scrollOffset, 0), 1)
        self.isFinished = isFinished
        self.updatedAt = updatedAt
    }

    /// Fração lida do capítulo, de 0 a 1.
    public var fraction: Double {
        guard pageCount > 0 else { return 0 }
        if isFinished { return 1 }
        return min(1, (Double(pageIndex) + scrollOffset) / Double(pageCount))
    }
}

public struct ReadingHistoryEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: Int64
    public var mangaId: Int64
    public var chapterId: Int64
    public var readAt: Date
    /// Tempo de leitura acumulado nesta sessão, em segundos.
    public var durationSeconds: Int

    public init(id: Int64 = 0, mangaId: Int64, chapterId: Int64, readAt: Date = Date(), durationSeconds: Int = 0) {
        self.id = id
        self.mangaId = mangaId
        self.chapterId = chapterId
        self.readAt = readAt
        self.durationSeconds = durationSeconds
    }
}

/// Linha exibida no Histórico.
public struct HistoryItem: Hashable, Sendable, Identifiable {
    public var entry: ReadingHistoryEntry
    public var manga: Manga
    public var chapter: Chapter
    public var progress: ReadingProgress?
    public var id: Int64 { entry.id }

    public init(entry: ReadingHistoryEntry, manga: Manga, chapter: Chapter, progress: ReadingProgress?) {
        self.entry = entry
        self.manga = manga
        self.chapter = chapter
        self.progress = progress
    }
}

// MARK: - Downloads

public enum DownloadState: String, Codable, Sendable, CaseIterable {
    case queued, downloading, paused, completed, failed, cancelled
}

public struct DownloadTask: Hashable, Codable, Sendable, Identifiable {
    public var id: Int64
    public var chapterId: Int64
    public var state: DownloadState
    public var downloadedPages: Int
    public var totalPages: Int
    public var bytes: Int64
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64 = 0, chapterId: Int64, state: DownloadState = .queued, downloadedPages: Int = 0,
                totalPages: Int = 0, bytes: Int64 = 0, errorMessage: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.chapterId = chapterId
        self.state = state
        self.downloadedPages = downloadedPages
        self.totalPages = totalPages
        self.bytes = bytes
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var progress: Double {
        totalPages > 0 ? Double(downloadedPages) / Double(totalPages) : 0
    }
}
