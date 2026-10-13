import Foundation
import FYCore
import FYDomain
import FYData
import FYSources

/// Opções da migração de um título para outra fonte (inspirado no "Migrar" do Mihon).
public struct MigrationOptions: Sendable {
    public var copyCategories = true
    public var copyReadState = true
    public var removeOldFromLibrary = true
    public init() {}
}

public struct GlobalSearchResult: Sendable, Identifiable {
    public let sourceId: SourceID
    public let sourceName: String
    public let items: [SourceManga]
    public let error: String?
    public var id: SourceID { sourceId }
}

extension LibraryService {
    /// Migra um título: busca o destino na nova fonte, copia categorias e o
    /// estado de leitura (capítulos com número ≤ ao maior número lido) e
    /// marcadores (mesmo número), adiciona o destino à biblioteca e, opcionalmente,
    /// remove o original da biblioteca (o histórico do original é preservado).
    @discardableResult
    public func migrate(mangaId: Int64, to target: SourceManga, sourceId: SourceID,
                        options: MigrationOptions = MigrationOptions()) async throws -> Manga {
        guard let old = try store.library.manga(id: mangaId) else { throw FYError.notFound("título original") }
        if old.sourceId == sourceId && old.key == target.key {
            throw FYError.invalidData("o destino é o próprio título")
        }
        let oldChapters = try store.chapters.chapters(mangaId: old.id)
        let oldCategories = try store.library.items().first { $0.manga.id == old.id }?.entry.categoryIds ?? []

        let (newManga, newChapters) = try await fetchAndStore(target, sourceId: sourceId)

        if options.copyReadState {
            let maxRead = oldChapters.filter { $0.isRead && $0.number >= 0 }.map(\.number).max()
            if let maxRead {
                let ids = newChapters.filter { $0.number >= 0 && $0.number <= maxRead + 0.0001 }.map(\.id)
                try store.chapters.setRead(ids, read: true)
            }
            let bookmarked = Set(oldChapters.filter { $0.isBookmarked && $0.number >= 0 }.map(\.number))
            for c in newChapters where bookmarked.contains(c.number) {
                try store.chapters.setBookmarked(c.id, true)
            }
        }
        try store.library.add(mangaId: newManga.id, categoryIds: options.copyCategories ? oldCategories : [])
        if options.removeOldFromLibrary {
            try store.library.remove(mangaIds: [old.id])
        }
        return newManga
    }

    /// Busca o termo em várias fontes ao mesmo tempo (no máximo `concurrency`
    /// simultâneas). Falhas de uma fonte não impedem as demais.
    public func globalSearch(_ query: String, sourceIds: [SourceID], concurrency: Int = 4) async -> [GlobalSearchResult] {
        let sources = sourceIds.compactMap { registry.source($0) }
        var results: [GlobalSearchResult] = []
        await withTaskGroup(of: GlobalSearchResult.self) { group in
            var iterator = sources.makeIterator()
            func addNext() {
                guard let s = iterator.next() else { return }
                group.addTask {
                    do {
                        let page = try await s.search(query: query, page: 1)
                        return GlobalSearchResult(sourceId: s.id, sourceName: s.name, items: page.items, error: nil)
                    } catch {
                        return GlobalSearchResult(sourceId: s.id, sourceName: s.name, items: [],
                                                  error: error.localizedDescription)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { addNext() }
            for await r in group {
                results.append(r)
                addNext()
            }
        }
        let order = Dictionary(uniqueKeysWithValues: sourceIds.enumerated().map { ($1, $0) })
        return results.sorted { (order[$0.sourceId] ?? 0) < (order[$1.sourceId] ?? 0) }
    }
}
