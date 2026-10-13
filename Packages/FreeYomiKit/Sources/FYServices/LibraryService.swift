import Foundation
import FYCore
import FYDomain
import FYData
import FYSources

/// Casos de uso que combinam fontes e persistência.
public final class LibraryService: @unchecked Sendable {
    public let store: DataStore
    public let registry: SourceRegistry

    public init(store: DataStore, registry: SourceRegistry) {
        self.store = store
        self.registry = registry
    }

    func source(_ id: SourceID) throws -> any MangaSource {
        guard let s = registry.source(id) else {
            throw FYError.unsupported("a fonte \(id) não está instalada neste aparelho")
        }
        return s
    }

    /// Persiste o título (sem adicioná-lo à biblioteca) e sincroniza capítulos.
    @discardableResult
    public func fetchAndStore(_ sm: SourceManga, sourceId: SourceID) async throws -> (Manga, [Chapter]) {
        let src = try source(sourceId)
        let details = try await src.details(for: sm)
        let remoteChapters = try await src.chapters(for: details)
        var manga = details.toManga(sourceId: sourceId, isDemo: src.kind == .demo)
        manga.id = try store.library.upsertManga(manga)
        // sourceOrder = posição na lista da fonte (0 = mais recente, convenção Mihon).
        let chapters = remoteChapters.enumerated().map { i, c in
            Chapter(mangaId: manga.id, key: c.key, name: c.name, number: c.number, scanlator: c.scanlator,
                    uploadDate: c.uploadDate, sourceOrder: i)
        }
        let stored = try store.chapters.upsert(chapters, mangaId: manga.id)
        try? store.sources.markUsed(sourceId)
        return (manga, stored)
    }

    /// Adiciona à biblioteca (buscando detalhes e capítulos na fonte).
    @discardableResult
    public func addToLibrary(_ sm: SourceManga, sourceId: SourceID, categoryIds: [Int64] = []) async throws -> Manga {
        let (manga, _) = try await fetchAndStore(sm, sourceId: sourceId)
        try store.library.add(mangaId: manga.id, categoryIds: categoryIds)
        return manga
    }

    /// Atualiza capítulos de todos os títulos da biblioteca. Retorna os
    /// capítulos novos encontrados por título.
    public func refreshLibrary(skipCompleted: Bool) async -> RefreshReport {
        var report = RefreshReport(startedAt: Date())
        let items = (try? store.library.items()) ?? []
        for item in items {
            if Task.isCancelled { break }
            if skipCompleted && item.manga.status == .completed { report.skipped += 1; continue }
            do {
                let before = Set(try store.chapters.chapters(mangaId: item.manga.id).map(\.key))
                let sm = SourceManga(key: item.manga.key, title: item.manga.title)
                let (_, after) = try await fetchAndStore(sm, sourceId: item.manga.sourceId)
                let new = after.filter { !before.contains($0.key) }
                if !new.isEmpty { report.newChapters.append((item.manga, new)) }
                report.updated += 1
            } catch {
                report.failures.append((item.manga.title, error.localizedDescription))
            }
        }
        report.finishedAt = Date()
        return report
    }

    /// Insere os títulos de demonstração na primeira execução.
    public func seedDemoDataIfNeeded() async throws {
        var settings = store.settings.load()
        guard !settings.demoDataSeeded else { return }
        let demo = DemoSource()
        try store.sources.upsert(demo.descriptor)
        for sm in try await demo.popular(page: 1).items {
            try await addToLibrary(sm, sourceId: demo.id)
        }
        // Algum histórico de exemplo, claramente vinculado aos títulos demo.
        let items = try store.library.items()
        let now = Date()
        for (offset, item) in items.prefix(3).enumerated() {
            let chapters = try store.chapters.chapters(mangaId: item.manga.id)
            guard let first = chapters.first else { continue }
            try store.progress.save(ReadingProgress(chapterId: first.id, mangaId: item.manga.id,
                                                    pageIndex: 3 + offset, pageCount: 14))
            try store.history.record(mangaId: item.manga.id, chapterId: first.id,
                                     at: now.addingTimeInterval(-Double(offset + 1) * 86_400 * 1.5),
                                     addingSeconds: 60 * (6 + offset * 13))
        }
        settings.demoDataSeeded = true
        try store.settings.save(settings)
    }

    /// Registra fontes nativas na tabela `sources` (para fixar / último uso).
    public func syncSourceTable() throws {
        for s in registry.all { try store.sources.upsert(s.descriptor) }
    }
}

public struct RefreshReport: @unchecked Sendable {
    public var startedAt: Date
    public var finishedAt: Date?
    public var updated = 0
    public var skipped = 0
    public var newChapters: [(Manga, [Chapter])] = []
    public var failures: [(String, String)] = []

    public init(startedAt: Date) { self.startedAt = startedAt }
}
