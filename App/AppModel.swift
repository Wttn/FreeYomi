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

    init(store: DataStore, registry: SourceRegistry, catalogCache: URL) {
        self.store = store
        self.registry = registry
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
        let registry = SourceRegistry.makeDefault()

        if ProcessInfo.processInfo.arguments.contains("-ui-testing"),
           let mem = try? DataStore.inMemory() {
            return AppModel(store: mem, registry: registry, catalogCache: caches.appendingPathComponent("ui-tests"))
        }

        let dbURL = support.appendingPathComponent("FreeYomi", isDirectory: true)
            .appendingPathComponent("library.sqlite")
        do {
            let store = try DataStore.open(fileURL: dbURL)
            let model = AppModel(store: store, registry: registry,
                                 catalogCache: caches.appendingPathComponent("catalog", isDirectory: true))
            if store.recoveredFromCorruption {
                model.startupNotice = "O banco de dados estava danificado e foi recriado. "
                    + "O arquivo original foi preservado para recuperação manual."
            }
            return model
        } catch {
            // Último recurso: banco temporário para o app abrir mesmo assim.
            let mem = try! DataStore.inMemory()
            let model = AppModel(store: mem, registry: registry, catalogCache: caches)
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
        } catch {
            report(error)
        }
        if let notice = startupNotice { alertMessage = notice }
        dataVersion += 1
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
