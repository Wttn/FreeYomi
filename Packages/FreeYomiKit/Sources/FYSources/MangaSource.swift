import Foundation
import FYDomain

/// Título como retornado por uma fonte (antes de ser persistido).
public struct SourceManga: Hashable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var author: String?
    public var artist: String?
    public var summary: String?
    public var genres: [String]
    public var status: PublicationStatus
    public var coverURL: String?
    public var id: String { key }

    public init(key: String, title: String, author: String? = nil, artist: String? = nil, summary: String? = nil,
                genres: [String] = [], status: PublicationStatus = .unknown, coverURL: String? = nil) {
        self.key = key
        self.title = title
        self.author = author
        self.artist = artist
        self.summary = summary
        self.genres = genres
        self.status = status
        self.coverURL = coverURL
    }

    public func toManga(sourceId: SourceID, isDemo: Bool) -> Manga {
        Manga(sourceId: sourceId, key: key, title: title, author: author, artist: artist, summary: summary,
              genres: genres, status: status, coverURL: coverURL, isDemo: isDemo)
    }
}

public struct SourceChapter: Hashable, Sendable {
    public var key: String
    public var name: String
    public var number: Double
    public var scanlator: String?
    public var uploadDate: Date?

    public init(key: String, name: String, number: Double = -1, scanlator: String? = nil, uploadDate: Date? = nil) {
        self.key = key
        self.name = name
        self.number = number
        self.scanlator = scanlator
        self.uploadDate = uploadDate
    }
}

public struct MangaListPage: Sendable {
    public var items: [SourceManga]
    public var hasNextPage: Bool
    public init(items: [SourceManga], hasNextPage: Bool) {
        self.items = items
        self.hasNextPage = hasNextPage
    }
}

/// Protocolo de fonte, independente da interface.
///
/// Cada adaptador é código Swift nativo, revisado e compilado com o app.
/// O FreeYomi NÃO baixa nem executa código de terceiros (APK/JAR/JS).
public protocol MangaSource: Sendable {
    var id: SourceID { get }
    var name: String { get }
    /// Código de idioma BCP-47 ("pt-BR", "en", "all"…).
    var language: String { get }
    var kind: SourceKind { get }
    var supportsSearch: Bool { get }
    var supportsLatest: Bool { get }

    func popular(page: Int) async throws -> MangaListPage
    func latest(page: Int) async throws -> MangaListPage
    func search(query: String, page: Int) async throws -> MangaListPage
    func details(for manga: SourceManga) async throws -> SourceManga
    func chapters(for manga: SourceManga) async throws -> [SourceChapter]
    func pages(mangaKey: String, chapterKey: String) async throws -> [Page]
}

extension MangaSource {
    public var supportsSearch: Bool { true }
    public var supportsLatest: Bool { false }
    public func latest(page: Int) async throws -> MangaListPage { try await popular(page: page) }

    public var descriptor: Source {
        Source(id: id, name: name, language: language, kind: kind)
    }
}

/// Estado de implementação exibido na tela de gerenciamento de fontes.
public enum SourceImplementationStatus: String, Sendable, CaseIterable {
    /// Adaptador nativo pronto para uso.
    case implemented
    /// Planejada, ainda não implementada (ex.: Komga na Fase 2/3).
    case planned
    /// Existe no catálogo Keiyoushi mas exige execução Android (APK/JAR).
    case requiresAndroid

    public var label: String {
        switch self {
        case .implemented: return "Implementada"
        case .planned: return "Aguardando desenvolvimento"
        case .requiresAndroid: return "Incompatível (requer Android)"
        }
    }
}

public struct SourceListing: Sendable, Identifiable, Hashable {
    public let id: SourceID
    public let name: String
    public let language: String
    public let kind: SourceKind
    public let status: SourceImplementationStatus
    public let note: String

    public init(id: SourceID, name: String, language: String, kind: SourceKind,
                status: SourceImplementationStatus, note: String) {
        self.id = id
        self.name = name
        self.language = language
        self.kind = kind
        self.status = status
        self.note = note
    }
}

/// Registro das fontes nativas disponíveis no app.
public final class SourceRegistry: @unchecked Sendable {
    private var sources: [SourceID: any MangaSource] = [:]
    private let lock = NSLock()

    public init(sources: [any MangaSource] = []) {
        for s in sources { self.sources[s.id] = s }
    }

    public static func makeDefault() -> SourceRegistry {
        SourceRegistry(sources: [DemoSource()])
    }

    public func register(_ s: any MangaSource) {
        lock.lock(); defer { lock.unlock() }
        sources[s.id] = s
    }

    public func source(_ id: SourceID) -> (any MangaSource)? {
        lock.lock(); defer { lock.unlock() }
        return sources[id]
    }

    public var all: [any MangaSource] {
        lock.lock(); defer { lock.unlock() }
        return sources.values.sorted { $0.name < $1.name }
    }

    /// Fontes implementadas + planejadas, para a tela "Explorar › Fontes".
    public func listings() -> [SourceListing] {
        var result = all.map {
            SourceListing(id: $0.id, name: $0.name, language: $0.language, kind: $0.kind, status: .implemented,
                          note: $0.kind == .demo ? "Dados fictícios gerados localmente" : "")
        }
        let planned: [SourceListing] = [
            SourceListing(id: .local, name: "Arquivos locais (CBZ/ZIP/pastas)", language: "all", kind: .localFiles,
                          status: .planned, note: "Fase 2 — importação pelo app Arquivos"),
            SourceListing(id: "komga", name: "Komga (servidor pessoal)", language: "all", kind: .personalServer,
                          status: .planned, note: "Fase 3 — adaptador nativo da API REST do Komga"),
        ]
        for p in planned where sources[p.id] == nil { result.append(p) }
        return result
    }
}
