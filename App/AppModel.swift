import Foundation
import Observation
import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Composição do aplicativo: banco local, fontes, serviços e preferências.
///
/// Tudo é local. Nenhum dado da biblioteca sai do aparelho.
@MainActor
@Observable
final class AppModel {
    let store: DataStore
    let registry: SourceRegistry
    let service: LibraryService
    let catalog: ExtensionCatalogClient
    /// Títulos importados (CBZ/ZIP/EPUB/pastas), dentro do contêiner do app.
    let localStore: LocalLibraryStore
    let importer: LocalImporter

    /// Importação em andamento e resultado da última.
    var isImporting = false
    var importStatus: String?

    /// Preferências; cada alteração é salva imediatamente no SQLite.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            do { try store.settings.save(settings) } catch { report(error) }
        }
    }

    /// Incrementado após qualquer mutação, para que as telas recarreguem.
    private(set) var dataVersion = 0

    /// Mensagem de erro exibida em alerta.
    var alertMessage: String?

    /// Aviso de inicialização (ex.: banco recuperado de corrupção).
    var startupNotice: String?

    /// Resultado da última verificação de atualizações.
    var lastRefresh: RefreshReport?
    var isRefreshing = false

    private var didBootstrap = false

    init(store: DataStore, registry: SourceRegistry, catalogCache: URL, localStore: LocalLibraryStore) {
        self.store = store
        self.registry = registry
        self.localStore = localStore
        self.importer = LocalImporter(store: localStore)
        ImagePipeline.shared.localRoot = localStore.root
        self.service = LibraryService(store: store, registry: registry)
        self.catalog = ExtensionCatalogClient(http: URLSessionHTTPClient(), cacheDirectory: catalogCache)
        self.settings = store.settings.load()
    }

    /// Abre o banco no diretório Application Support. Em testes de interface
    /// (`-ui-testing`) usa um banco em memória.
    static func makeForLaunch() -> AppModel {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                                   create: true)) ?? fm.temporaryDirectory
        let caches = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let uiTesting = ProcessInfo.processInfo.arguments.contains("-ui-testing")
        let localRoot = uiTesting
            ? fm.temporaryDirectory.appendingPathComponent("ui-tests-local-\(UUID().uuidString)", isDirectory: true)
            : support.appendingPathComponent("FreeYomi/LocalFiles", isDirectory: true)
        let localStore = LocalLibraryStore(root: localRoot)
        let registry = SourceRegistry.makeDefault(localStore: localStore)

        if uiTesting, let mem = try? DataStore.inMemory() {
            return AppModel(store: mem, registry: registry, catalogCache: caches.appendingPathComponent("ui-tests"),
                            localStore: localStore)
        }

        let dbURL = support.appendingPathComponent("FreeYomi", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        do {
            let store = try DataStore.open(fileURL: dbURL)
            let model = AppModel(store: store, registry: registry,
                                 catalogCache: caches.appendingPathComponent("catalog", isDirectory: true),
                                 localStore: localStore)
            if store.recoveredFromCorruption {
                model.startupNotice = "O banco de dados estava danificado e foi recriado. "
                    + "O arquivo original foi preservado para recuperação manual."
            }
            return model
        } catch {
            // Último recurso: banco temporário para o app abrir mesmo assim.
            let mem = try! DataStore.inMemory()
            let model = AppModel(store: mem, registry: registry, catalogCache: caches, localStore: localStore)
            model.startupNotice = "Não foi possível abrir a biblioteca local (\(error.localizedDescription)). "
                + "Os dados desta sessão não serão salvos."
            return model
        }
    }

    /// Prepara fontes e dados de demonstração. Não depende de internet.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        do {
            try service.syncSourceTable()
            try await service.seedDemoDataIfNeeded()
            settings = store.settings.load()
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-sample"),
               let sample = try? SampleArchive.make() {
                await importFiles([sample], securityScoped: false)
            }
        } catch {
            report(error)
        }
        if let notice = startupNotice { alertMessage = notice }
        dataVersion += 1
        let disk = ImagePipeline.shared.disk
        Task.detached(priority: .background) { disk.trim() }
    }

    // MARK: - Mutações

    /// Executa uma alteração no banco, informa erros e notifica as telas.
    func mutate(_ body: () throws -> Void) {
        do {
            try body()
            dataVersion += 1
        } catch {
            report(error)
        }
    }

    func touch() { dataVersion += 1 }

    func report(_ error: Error) {
        if let fy = error as? FYError, fy == .cancelled { return }
        alertMessage = error.localizedDescription
    }

    func refreshLibrary() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefresh = await service.refreshLibrary(skipCompleted: settings.skipUpdatingCompleted)
        dataVersion += 1
    }

    func restoreDemoData() async {
        var s = settings
        s.demoDataSeeded = false
        settings = s
        do {
            try await service.seedDemoDataIfNeeded()
            settings = store.settings.load()
        } catch { report(error) }
        dataVersion += 1
    }

    // MARK: - Arquivos locais

    /// Importa arquivos/pastas escolhidos pelo usuário. URLs do seletor de
    /// arquivos são "security-scoped": o acesso é liberado só durante a cópia.
    func importFiles(_ urls: [URL], securityScoped: Bool = true) async {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        importStatus = urls.count == 1 ? "Importando \(urls[0].lastPathComponent)…" : "Importando \(urls.count) itens…"
        let granted = securityScoped ? urls.map { $0.startAccessingSecurityScopedResource() } : []
        let categories = settings.defaultCategoryId.map { [$0] } ?? []
        let report = await service.importLocal(urls: urls, importer: importer, categoryIds: categories)
        for (url, ok) in zip(urls, granted) where ok { url.stopAccessingSecurityScopedResource() }
        isImporting = false
        importStatus = nil
        dataVersion += 1

        var lines: [String] = []
        if !report.imported.isEmpty {
            lines.append("Importado(s): " + report.imported.map(\.title).joined(separator: ", ") + ".")
        }
        if !report.duplicates.isEmpty {
            lines.append("Já estavam na biblioteca: " + report.duplicates.joined(separator: ", ") + ".")
        }
        for f in report.failures { lines.append("Falha em \(f.name): \(f.reason)") }
        if report.skippedFiles > 0 { lines.append("\(report.skippedFiles) arquivo(s) que não são imagens foram ignorados.") }
        if !report.failures.isEmpty || !report.duplicates.isEmpty || report.skippedFiles > 0 {
            alertMessage = lines.joined(separator: "\n")
        } else if !report.imported.isEmpty {
            Haptics.success()
        }
    }

    /// Arquivo aberto a partir de outro app ("Abrir com FreeYomi").
    func handleOpenURL(_ url: URL) {
        Task {
            await importFiles([url], securityScoped: true)
            // Cópias recebidas em Documents/Inbox não são mais necessárias.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        }
    }

    func deleteLocalFiles(of manga: Manga) {
        mutate { try service.deleteLocalManga(manga, store: localStore) }
    }

    func removeDemoData() {
        mutate { try store.library.deleteDemoData() }
    }
}

extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
