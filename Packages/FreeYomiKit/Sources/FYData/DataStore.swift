import Foundation
import FYCore
import FYDomain

/// Ponto de entrada da camada de dados. Abre o banco, aplica migrações,
/// recupera-se de arquivos corrompidos e expõe os repositórios.
public final class DataStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    /// `true` se o arquivo anterior estava corrompido e foi preservado à parte.
    public let recoveredFromCorruption: Bool
    /// Caminho do arquivo corrompido preservado, se houver.
    public let corruptedBackupPath: String?

    public let sources: SourceRepository
    public let library: LibraryRepository
    public let chapters: ChapterRepository
    public let progress: ProgressRepository
    public let history: HistoryRepository
    public let categories: CategoryRepository
    public let downloads: DownloadRepository
    public let settings: SettingsRepository

    /// Abre o banco em `url`. Se o arquivo estiver corrompido, ele é renomeado
    /// para `<nome>.corrupt-<timestamp>` (nunca apagado) e um banco novo é criado.
    public static func open(fileURL url: URL) throws -> DataStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path)
            guard db.integrityCheck() else { throw FYError.database("verificação de integridade falhou") }
            try Migrator.migrate(db)
            return DataStore(db: db, recovered: false, backupPath: nil)
        } catch FYError.database(let message) where message.contains("versão mais nova") {
            // Nunca descartar dados criados por uma versão futura do app.
            throw FYError.database(message)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = url.path + ".corrupt-\(stamp)"
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try? fm.moveItem(atPath: url.path, toPath: backup)
                for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: url.path + suffix) }
            }
            let db = try SQLiteDatabase(path: url.path)
            try Migrator.migrate(db)
            return DataStore(db: db, recovered: true, backupPath: backup)
        }
    }

    /// Banco em memória, para testes e pré-visualizações.
    public static func inMemory() throws -> DataStore {
        let db = try SQLiteDatabase(path: ":memory:")
        try Migrator.migrate(db)
        return DataStore(db: db, recovered: false, backupPath: nil)
    }

    private init(db: SQLiteDatabase, recovered: Bool, backupPath: String?) {
        self.db = db
        self.recoveredFromCorruption = recovered
        self.corruptedBackupPath = backupPath
        sources = SourceRepository(db: db)
        library = LibraryRepository(db: db)
        chapters = ChapterRepository(db: db)
        progress = ProgressRepository(db: db)
        history = HistoryRepository(db: db)
        categories = CategoryRepository(db: db)
        downloads = DownloadRepository(db: db)
        settings = SettingsRepository(db: db)
    }
}

// MARK: - Mapeamento de linhas

extension Manga {
    init(row: SQLRow) {
        self.init(
            id: row.int64("id"),
            sourceId: SourceID(row.string("source_id")),
            key: row.string("key"),
            title: row.string("title"),
            author: row.optionalString("author"),
            artist: row.optionalString("artist"),
            summary: row.optionalString("summary"),
            genres: row.string("genres").split(separator: "\u{1F}").map(String.init),
            status: PublicationStatus(rawValue: row.int("status")) ?? .unknown,
            coverURL: row.optionalString("cover_url"),
            isDemo: row.bool("is_demo"),
            updatedAt: row.date("updated_at")
        )
    }
}

extension Chapter {
    init(row: SQLRow, prefix: String = "") {
        self.init(
            id: row.int64(prefix + "id"),
            mangaId: row.int64(prefix + "manga_id"),
            key: row.string(prefix + "key"),
            name: row.string(prefix + "name"),
            number: row.double(prefix + "number"),
            scanlator: row.optionalString(prefix + "scanlator"),
            uploadDate: row.optionalDate(prefix + "upload_date"),
            sourceOrder: row.int(prefix + "source_order"),
            isRead: row.bool(prefix + "is_read"),
            isBookmarked: row.bool(prefix + "is_bookmarked"),
            fetchedAt: row.date(prefix + "fetched_at")
        )
    }
}

extension ReadingProgress {
    init(row: SQLRow) {
        self.init(chapterId: row.int64("chapter_id"), mangaId: row.int64("manga_id"),
                  pageIndex: row.int("page_index"), pageCount: row.int("page_count"),
                  scrollOffset: row.double("scroll_offset"), isFinished: row.bool("is_finished"),
                  updatedAt: row.date("updated_at"))
    }
}

// MARK: - Fontes

public struct SourceRepository: Sendable {
    let db: SQLiteDatabase

    public func upsert(_ s: Source) throws {
        try db.run("""
            INSERT INTO sources (id, name, language, kind, is_enabled, is_pinned, last_used_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, language = excluded.language, kind = excluded.kind
            """, s.id.rawValue, s.name, s.language, s.kind.rawValue, s.isEnabled, s.isPinned, s.lastUsedAt)
    }

    public func all() throws -> [Source] {
        try db.query("SELECT * FROM sources ORDER BY is_pinned DESC, name COLLATE NOCASE").map {
            Source(id: SourceID($0.string("id")), name: $0.string("name"), language: $0.string("language"),
                   kind: SourceKind(rawValue: $0.string("kind")) ?? .online, isEnabled: $0.bool("is_enabled"),
                   isPinned: $0.bool("is_pinned"), lastUsedAt: $0.optionalDate("last_used_at"))
        }
    }

    public func setPinned(_ id: SourceID, _ pinned: Bool) throws {
        try db.run("UPDATE sources SET is_pinned = ? WHERE id = ?", pinned, id.rawValue)
    }

    public func markUsed(_ id: SourceID, at date: Date = Date()) throws {
        try db.run("UPDATE sources SET last_used_at = ? WHERE id = ?", date, id.rawValue)
    }
}

// MARK: - Biblioteca

public struct LibraryRepository: Sendable {
    let db: SQLiteDatabase

    /// Insere ou atualiza um título pela chave composta `(source_id, key)`.
    /// Retorna o ID local estável.
    @discardableResult
    public func upsertManga(_ m: Manga) throws -> Int64 {
        try db.transaction {
            try db.run("""
                INSERT INTO manga (source_id, key, title, author, artist, summary, genres, status, cover_url, is_demo, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, key) DO UPDATE SET
                    title = excluded.title, author = excluded.author, artist = excluded.artist,
                    summary = excluded.summary, genres = excluded.genres, status = excluded.status,
                    cover_url = excluded.cover_url, is_demo = excluded.is_demo, updated_at = excluded.updated_at
                """, m.sourceId.rawValue, m.key, m.title, m.author, m.artist, m.summary,
                       m.genres.joined(separator: "\u{1F}"), m.status.rawValue, m.coverURL, m.isDemo, m.updatedAt)
            let row = try db.query("SELECT id FROM manga WHERE source_id = ? AND key = ?", m.sourceId.rawValue, m.key)
            guard let id = row.first?.int64("id") else { throw FYError.database("título não persistido") }
            return id
        }
    }

    public func manga(id: Int64) throws -> Manga? {
        try db.query("SELECT * FROM manga WHERE id = ?", id).first.map(Manga.init(row:))
    }

    public func manga(key: MangaKey) throws -> Manga? {
        try db.query("SELECT * FROM manga WHERE source_id = ? AND key = ?", key.sourceId.rawValue, key.key)
            .first.map(Manga.init(row:))
    }

    public func add(mangaId: Int64, categoryIds: [Int64] = [], at date: Date = Date()) throws {
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO library (manga_id, added_at) VALUES (?, ?)", mangaId, date)
            try setCategories(mangaId: mangaId, categoryIds: categoryIds)
        }
    }

    public func remove(mangaIds: [Int64]) throws {
        try db.transaction {
            for id in mangaIds { try db.run("DELETE FROM library WHERE manga_id = ?", id) }
        }
    }

    public func isInLibrary(mangaId: Int64) throws -> Bool {
        try !db.query("SELECT 1 FROM library WHERE manga_id = ?", mangaId).isEmpty
    }

    public func setCategories(mangaId: Int64, categoryIds: [Int64]) throws {
        try db.transaction {
            try db.run("DELETE FROM manga_categories WHERE manga_id = ?", mangaId)
            for c in categoryIds {
                try db.run("INSERT OR IGNORE INTO manga_categories (manga_id, category_id) VALUES (?, ?)", mangaId, c)
            }
        }
    }

    /// Itens da biblioteca com contagem de não lidos e última leitura.
    /// - Parameters:
    ///   - categoryId: filtra por categoria (`nil` = todas).
    ///   - search: filtra por título/autor (sem diferenciar maiúsculas).
    public func items(categoryId: Int64? = nil, search: String? = nil, sort: LibrarySort = .alphabetical) throws -> [LibraryItem] {
        var sql = """
            SELECT m.*, l.added_at AS l_added_at,
                (SELECT COUNT(*) FROM chapters c WHERE c.manga_id = m.id AND c.is_read = 0) AS unread,
                (SELECT COUNT(*) FROM chapters c WHERE c.manga_id = m.id) AS total,
                (SELECT MAX(h.read_at) FROM history h WHERE h.manga_id = m.id) AS last_read_at,
                (SELECT c.name FROM history h JOIN chapters c ON c.id = h.chapter_id
                    WHERE h.manga_id = m.id ORDER BY h.read_at DESC LIMIT 1) AS last_chapter,
                (SELECT GROUP_CONCAT(mc.category_id) FROM manga_categories mc WHERE mc.manga_id = m.id) AS cats
            FROM library l JOIN manga m ON m.id = l.manga_id
            """
        var args: [SQLBindable] = []
        var conditions: [String] = []
        if let categoryId {
            conditions.append("EXISTS (SELECT 1 FROM manga_categories mc WHERE mc.manga_id = m.id AND mc.category_id = ?)")
            args.append(categoryId)
        }
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            conditions.append("(m.title LIKE ? ESCAPE '\\' OR IFNULL(m.author, '') LIKE ? ESCAPE '\\')")
            let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            args.append("%\(escaped)%")
            args.append("%\(escaped)%")
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        switch sort {
        case .alphabetical: sql += " ORDER BY m.title COLLATE NOCASE"
        case .lastRead: sql += " ORDER BY last_read_at IS NULL, last_read_at DESC, m.title COLLATE NOCASE"
        case .dateAdded: sql += " ORDER BY l.added_at DESC"
        case .unreadCount: sql += " ORDER BY unread DESC, m.title COLLATE NOCASE"
        }

        return try db.query(sql, arguments: args).map { row in
            let cats = row.optionalString("cats")?.split(separator: ",").compactMap { Int64($0) } ?? []
            return LibraryItem(
                manga: Manga(row: row),
                entry: LibraryEntry(mangaId: row.int64("id"), addedAt: row.date("l_added_at"), categoryIds: cats),
                unreadCount: row.int("unread"),
                totalChapters: row.int("total"),
                lastReadAt: row.optionalDate("last_read_at"),
                lastReadChapterName: row.optionalString("last_chapter")
            )
        }
    }

    /// Remove todos os títulos marcados como demonstração (e seus dados).
    public func deleteDemoData() throws {
        try db.run("DELETE FROM manga WHERE is_demo = 1")
    }
}

// MARK: - Capítulos

public struct ChapterRepository: Sendable {
    let db: SQLiteDatabase

    /// Sincroniza capítulos de um título preservando o estado de leitura dos
    /// capítulos já conhecidos (chave composta `(manga_id, key)`).
    @discardableResult
    public func upsert(_ chapters: [Chapter], mangaId: Int64) throws -> [Chapter] {
        try db.transaction {
            for c in chapters {
                try db.run("""
                    INSERT INTO chapters (manga_id, key, name, number, scanlator, upload_date, source_order, is_read, is_bookmarked, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(manga_id, key) DO UPDATE SET
                        name = excluded.name, number = excluded.number, scanlator = excluded.scanlator,
                        upload_date = excluded.upload_date, source_order = excluded.source_order
                    """, mangaId, c.key, c.name, c.number, c.scanlator, c.uploadDate, c.sourceOrder,
                           c.isRead, c.isBookmarked, c.fetchedAt)
            }
            return try self.chapters(mangaId: mangaId)
        }
    }

    /// Capítulos em ordem de leitura (do primeiro para o último).
    public func chapters(mangaId: Int64) throws -> [Chapter] {
        try db.query("SELECT * FROM chapters WHERE manga_id = ? ORDER BY source_order DESC, number ASC", mangaId)
            .map { Chapter(row: $0) }
    }

    public func chapter(id: Int64) throws -> Chapter? {
        try db.query("SELECT * FROM chapters WHERE id = ?", id).first.map { Chapter(row: $0) }
    }

    public func setRead(_ ids: [Int64], read: Bool) throws {
        try db.transaction {
            for id in ids { try db.run("UPDATE chapters SET is_read = ? WHERE id = ?", read, id) }
        }
    }

    public func setBookmarked(_ id: Int64, _ value: Bool) throws {
        try db.run("UPDATE chapters SET is_bookmarked = ? WHERE id = ?", value, id)
    }
}

// MARK: - Progresso

public struct ProgressRepository: Sendable {
    let db: SQLiteDatabase

    /// Salva o progresso. Ao terminar o capítulo, marca-o como lido.
    public func save(_ p: ReadingProgress) throws {
        try db.transaction {
            try db.run("""
                INSERT INTO reading_progress (chapter_id, manga_id, page_index, page_count, scroll_offset, is_finished, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(chapter_id) DO UPDATE SET
                    page_index = excluded.page_index, page_count = excluded.page_count,
                    scroll_offset = excluded.scroll_offset, is_finished = excluded.is_finished,
                    updated_at = excluded.updated_at
                """, p.chapterId, p.mangaId, p.pageIndex, p.pageCount, p.scrollOffset, p.isFinished, p.updatedAt)
            if p.isFinished {
                try db.run("UPDATE chapters SET is_read = 1 WHERE id = ?", p.chapterId)
            }
        }
    }

    public func progress(chapterId: Int64) throws -> ReadingProgress? {
        try db.query("SELECT * FROM reading_progress WHERE chapter_id = ?", chapterId).first.map(ReadingProgress.init(row:))
    }

    public func progress(mangaId: Int64) throws -> [ReadingProgress] {
        try db.query("SELECT * FROM reading_progress WHERE manga_id = ?", mangaId).map(ReadingProgress.init(row:))
    }
}

// MARK: - Histórico

public struct HistoryRepository: Sendable {
    let db: SQLiteDatabase

    /// Registra a leitura de um capítulo (um registro por capítulo; a data é
    /// atualizada e o tempo de leitura é acumulado).
    public func record(mangaId: Int64, chapterId: Int64, at date: Date = Date(), addingSeconds: Int = 0) throws {
        try db.run("""
            INSERT INTO history (manga_id, chapter_id, read_at, duration_seconds) VALUES (?, ?, ?, ?)
            ON CONFLICT(chapter_id) DO UPDATE SET
                read_at = excluded.read_at,
                duration_seconds = history.duration_seconds + excluded.duration_seconds
            """, mangaId, chapterId, date, max(0, addingSeconds))
    }

    public func recent(limit: Int = 200, search: String? = nil) throws -> [HistoryItem] {
        var sql = """
            SELECT h.id AS h_id, h.manga_id AS h_manga_id, h.chapter_id AS h_chapter_id,
                   h.read_at AS h_read_at, h.duration_seconds AS h_duration,
                   m.*,
                   c.id AS c_id, c.manga_id AS c_manga_id, c.key AS c_key, c.name AS c_name, c.number AS c_number,
                   c.scanlator AS c_scanlator, c.upload_date AS c_upload_date, c.source_order AS c_source_order,
                   c.is_read AS c_is_read, c.is_bookmarked AS c_is_bookmarked, c.fetched_at AS c_fetched_at,
                   p.page_index AS p_page_index, p.page_count AS p_page_count, p.scroll_offset AS p_scroll_offset,
                   p.is_finished AS p_is_finished, p.updated_at AS p_updated_at
            FROM history h
            JOIN manga m ON m.id = h.manga_id
            JOIN chapters c ON c.id = h.chapter_id
            LEFT JOIN reading_progress p ON p.chapter_id = h.chapter_id
            """
        var args: [SQLBindable] = []
        if let search, !search.isEmpty {
            sql += " WHERE m.title LIKE ?"
            args.append("%\(search)%")
        }
        sql += " ORDER BY h.read_at DESC LIMIT ?"
        args.append(limit)

        return try db.query(sql, arguments: args).map { row in
            let entry = ReadingHistoryEntry(id: row.int64("h_id"), mangaId: row.int64("h_manga_id"),
                                            chapterId: row.int64("h_chapter_id"), readAt: row.date("h_read_at"),
                                            durationSeconds: row.int("h_duration"))
            var progress: ReadingProgress?
            if row.optionalInt64("p_page_index") != nil {
                progress = ReadingProgress(chapterId: entry.chapterId, mangaId: entry.mangaId,
                                           pageIndex: row.int("p_page_index"), pageCount: row.int("p_page_count"),
                                           scrollOffset: row.double("p_scroll_offset"),
                                           isFinished: row.bool("p_is_finished"), updatedAt: row.date("p_updated_at"))
            }
            return HistoryItem(entry: entry, manga: Manga(row: row), chapter: Chapter(row: row, prefix: "c_"),
                               progress: progress)
        }
    }

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM history WHERE id = ?", id)
    }

    public func deleteAll(mangaId: Int64) throws {
        try db.run("DELETE FROM history WHERE manga_id = ?", mangaId)
    }

    public func clearAll() throws {
        try db.run("DELETE FROM history")
    }
}

// MARK: - Categorias

public struct CategoryRepository: Sendable {
    let db: SQLiteDatabase

    @discardableResult
    public func create(name: String) throws -> MangaCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FYError.invalidData("nome de categoria vazio") }
        return try db.transaction {
            let order = (try db.query("SELECT IFNULL(MAX(sort_order), -1) + 1 AS n FROM categories").first?.int("n")) ?? 0
            try db.run("INSERT INTO categories (name, sort_order) VALUES (?, ?)", trimmed, order)
            return MangaCategory(id: db.lastInsertRowID, name: trimmed, order: order)
        }
    }

    public func all() throws -> [MangaCategory] {
        try db.query("SELECT * FROM categories ORDER BY sort_order, name COLLATE NOCASE").map {
            MangaCategory(id: $0.int64("id"), name: $0.string("name"), order: $0.int("sort_order"))
        }
    }

    public func rename(id: Int64, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FYError.invalidData("nome de categoria vazio") }
        try db.run("UPDATE categories SET name = ? WHERE id = ?", trimmed, id)
    }

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM categories WHERE id = ?", id)
    }

    public func reorder(_ ids: [Int64]) throws {
        try db.transaction {
            for (i, id) in ids.enumerated() { try db.run("UPDATE categories SET sort_order = ? WHERE id = ?", i, id) }
        }
    }
}

// MARK: - Downloads (estrutura; o gerenciador chega na Fase 4)

public struct DownloadRepository: Sendable {
    let db: SQLiteDatabase

    /// Enfileira um download. Evita duplicatas pelo capítulo.
    @discardableResult
    public func enqueue(chapterId: Int64, totalPages: Int = 0) throws -> DownloadTask {
        try db.transaction {
            let now = Date()
            try db.run("""
                INSERT OR IGNORE INTO downloads (chapter_id, state, total_pages, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, chapterId, DownloadState.queued.rawValue, totalPages, now, now)
            guard let t = try task(chapterId: chapterId) else { throw FYError.database("download não criado") }
            return t
        }
    }

    public func task(chapterId: Int64) throws -> DownloadTask? {
        try db.query("SELECT * FROM downloads WHERE chapter_id = ?", chapterId).first.map(Self.map)
    }

    public func all() throws -> [DownloadTask] {
        try db.query("SELECT * FROM downloads ORDER BY created_at").map(Self.map)
    }

    public func update(_ t: DownloadTask) throws {
        try db.run("""
            UPDATE downloads SET state = ?, downloaded_pages = ?, total_pages = ?, bytes = ?, error_message = ?, updated_at = ?
            WHERE id = ?
            """, t.state.rawValue, t.downloadedPages, t.totalPages, t.bytes, t.errorMessage, Date(), t.id)
    }

    public func delete(id: Int64) throws {
        try db.run("DELETE FROM downloads WHERE id = ?", id)
    }

    static func map(_ r: SQLRow) -> DownloadTask {
        DownloadTask(id: r.int64("id"), chapterId: r.int64("chapter_id"),
                     state: DownloadState(rawValue: r.string("state")) ?? .failed,
                     downloadedPages: r.int("downloaded_pages"), totalPages: r.int("total_pages"),
                     bytes: r.int64("bytes"), errorMessage: r.optionalString("error_message"),
                     createdAt: r.date("created_at"), updatedAt: r.date("updated_at"))
    }
}

// MARK: - Preferências

public struct SettingsRepository: Sendable {
    let db: SQLiteDatabase
    static let key = "app_settings"

    /// Carrega as preferências. Se o JSON salvo estiver inválido, volta ao padrão.
    public func load() -> AppSettings {
        guard let json = try? db.query("SELECT value FROM settings WHERE key = ?", Self.key).first?.string("value"),
              let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    public func save(_ s: AppSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(s), as: UTF8.self)
        try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                   Self.key, json)
    }
}
