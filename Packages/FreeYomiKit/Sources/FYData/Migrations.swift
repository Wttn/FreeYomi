import Foundation
import FYCore

/// Migração de esquema. Cada versão é aplicada uma única vez, em transação.
public struct Migration: Sendable {
    public let version: Int
    public let name: String
    public let sql: String
}

public enum Migrator {
    /// Lista ordenada de migrações. NUNCA altere uma migração já publicada:
    /// acrescente uma nova versão.
    public static let migrations: [Migration] = [
        Migration(version: 1, name: "esquema inicial", sql: """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            language TEXT NOT NULL,
            kind TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            last_used_at REAL
        );

        CREATE TABLE manga (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_id TEXT NOT NULL,
            key TEXT NOT NULL,
            title TEXT NOT NULL,
            author TEXT,
            artist TEXT,
            summary TEXT,
            genres TEXT NOT NULL DEFAULT '',
            status INTEGER NOT NULL DEFAULT 0,
            cover_url TEXT,
            is_demo INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            UNIQUE (source_id, key)
        );

        CREATE TABLE chapters (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            key TEXT NOT NULL,
            name TEXT NOT NULL,
            number REAL NOT NULL DEFAULT -1,
            scanlator TEXT,
            upload_date REAL,
            source_order INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0,
            is_bookmarked INTEGER NOT NULL DEFAULT 0,
            fetched_at REAL NOT NULL,
            UNIQUE (manga_id, key)
        );
        CREATE INDEX idx_chapters_manga ON chapters(manga_id);

        CREATE TABLE library (
            manga_id INTEGER PRIMARY KEY NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            added_at REAL NOT NULL
        );

        CREATE TABLE categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            sort_order INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE manga_categories (
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            category_id INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
            PRIMARY KEY (manga_id, category_id)
        );

        CREATE TABLE reading_progress (
            chapter_id INTEGER PRIMARY KEY NOT NULL REFERENCES chapters(id) ON DELETE CASCADE,
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            page_index INTEGER NOT NULL,
            page_count INTEGER NOT NULL,
            scroll_offset REAL NOT NULL DEFAULT 0,
            is_finished INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );

        CREATE TABLE history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            manga_id INTEGER NOT NULL REFERENCES manga(id) ON DELETE CASCADE,
            chapter_id INTEGER NOT NULL UNIQUE REFERENCES chapters(id) ON DELETE CASCADE,
            read_at REAL NOT NULL,
            duration_seconds INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX idx_history_read_at ON history(read_at DESC);

        CREATE TABLE downloads (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chapter_id INTEGER NOT NULL UNIQUE REFERENCES chapters(id) ON DELETE CASCADE,
            state TEXT NOT NULL,
            downloaded_pages INTEGER NOT NULL DEFAULT 0,
            total_pages INTEGER NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """),
        Migration(version: 2, name: "repositórios e extensões instaladas", sql: """
        CREATE TABLE extension_repositories (
            url TEXT PRIMARY KEY NOT NULL,
            canonical_key TEXT NOT NULL UNIQUE,
            name TEXT,
            badge_label TEXT,
            website TEXT,
            discord TEXT,
            signing_key TEXT,
            format TEXT,
            extension_count INTEGER,
            position INTEGER NOT NULL DEFAULT 0,
            allows_http INTEGER NOT NULL DEFAULT 0,
            added_at REAL NOT NULL,
            last_sync_at REAL,
            last_sync_ok INTEGER,
            last_sync_error TEXT
        );

        CREATE TABLE installed_extensions (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            repository_url TEXT,
            version_code INTEGER NOT NULL,
            version_name TEXT NOT NULL,
            adapter TEXT NOT NULL,
            adapter_version INTEGER NOT NULL,
            manifest BLOB NOT NULL,
            sha256 TEXT NOT NULL,
            integrity_verified INTEGER NOT NULL DEFAULT 0,
            auto_update INTEGER NOT NULL DEFAULT 0,
            installed_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            last_error TEXT
        );
        """),
    ]

    public static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Aplica as migrações pendentes. Retorna as versões aplicadas.
    @discardableResult
    public static func migrate(_ db: SQLiteDatabase, upTo target: Int = latestVersion) throws -> [Int] {
        let current = db.userVersion
        if current > latestVersion {
            throw FYError.database(
                "o banco foi criado por uma versão mais nova do app (esquema \(current) > \(latestVersion))")
        }
        var applied: [Int] = []
        for m in migrations where m.version > current && m.version <= target {
            try db.transaction {
                try db.execute(m.sql)
                try db.setUserVersion(m.version)
            }
            applied.append(m.version)
        }
        return applied
    }
}
