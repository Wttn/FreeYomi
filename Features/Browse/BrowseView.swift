import SwiftUI
import FYDomain
import FYSources
import FYCore
import FYData
import FYServices

/// Explorar — referência: captura "Explorar" (abas Fontes / Extensões /
/// Migrar, seções "Último usado" e por idioma, ações de configurar e fixar).
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var segment: Segment = .sources

    enum Segment: String, CaseIterable, Identifiable {
        case sources = "Fontes"
        case extensions = "Extensões"
        case migrate = "Migrar"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Seção", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, FYMetrics.screenPadding)
                .padding(.bottom, 8)

                switch segment {
                case .sources: SourcesListView()
                case .extensions: ExtensionsTabView()
                case .migrate: MigrateView()
                }
            }
            .navigationTitle("Explorar")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        GlobalSearchView()
                    } label: { Label("Busca global", systemImage: "magnifyingglass") }
                }
            }
            .navigationDestination(for: SourceID.self) { SourceCatalogView(sourceId: $0) }
            .navigationDestination(for: Int64.self) { MangaDetailView(mangaId: $0) }
        }
    }
}

// MARK: - Fontes

struct SourcesListView: View {
    @Environment(AppModel.self) private var model
    @State private var stored: [SourceID: Source] = [:]
    @State private var infoFor: SourceListing?

    var body: some View {
        let listings = model.registry.listings()
        let implemented = listings.filter { $0.status == .implemented }
        let lastUsed = implemented
            .compactMap { l in stored[l.id]?.lastUsedAt.map { (l, $0) } }
            .max { $0.1 < $1.1 }?.0
        let pinned = implemented.filter { stored[$0.id]?.isPinned == true }
        let byLanguage = Dictionary(grouping: implemented, by: { $0.language.lowercased() })

        List {
            if let lastUsed {
                Section("Último usado") { row(lastUsed) }
            }
            if !pinned.isEmpty {
                Section("Fixadas") { ForEach(pinned) { row($0) } }
            }
            ForEach(byLanguage.keys.sorted(), id: \.self) { lang in
                Section(LanguageName.display(lang)) {
                    ForEach(byLanguage[lang] ?? []) { row($0) }
                }
            }
            Section {
                ForEach(listings.filter { $0.status != .implemented }) { row($0) }
            } header: {
                Text("Em desenvolvimento")
            } footer: {
                Text("O FreeYomi só lista como disponível uma fonte com adaptador nativo para iOS. "
                     + "Extensões Android do catálogo aparecem na aba Extensões, marcadas como incompatíveis.")
            }
        }
        .listStyle(.insetGrouped)
        .task(id: model.dataVersion) {
            stored = Dictionary(uniqueKeysWithValues: ((try? model.store.sources.all()) ?? []).map { ($0.id, $0) })
        }
        .sheet(item: $infoFor) { SourceInfoSheet(listing: $0) }
    }

    @ViewBuilder
    private func row(_ l: SourceListing) -> some View {
        let available = l.status == .implemented
        HStack(spacing: 14) {
            SourceIcon(kind: l.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name).font(.body)
                Text(available ? LanguageName.display(l.language) : l.status.label)
                    .font(.caption)
                    .foregroundStyle(available ? Color.secondary : Color.orange)
            }
            Spacer()
            Button { infoFor = l } label: { Image(systemName: "gearshape.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Detalhes de \(l.name)")
            if available {
                let isPinned = stored[l.id]?.isPinned == true
                Button {
                    model.mutate { try model.store.sources.setPinned(l.id, !isPinned) }
                    Haptics.tap()
                } label: { Image(systemName: isPinned ? "pin.fill" : "pin") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPinned ? "Desafixar" : "Fixar")
            }
        }
        .foregroundStyle(.primary)
        .background {
            if available { NavigationLink(value: l.id) { EmptyView() }.opacity(0) }
        }
        .opacity(available ? 1 : 0.7)
    }
}

struct SourceIcon: View {
    let kind: SourceKind
    var body: some View {
        Image(systemName: icon)
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private var icon: String {
        switch kind {
        case .demo: return "sparkles.rectangle.stack"
        case .localFiles: return "folder"
        case .personalServer: return "server.rack"
        case .online: return "globe"
        }
    }
}

struct SourceInfoSheet: View {
    let listing: SourceListing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Nome", value: listing.name)
                LabeledContent("Idioma", value: LanguageName.display(listing.language))
                LabeledContent("Situação", value: listing.status.label)
                LabeledContent("Identificador", value: listing.id.rawValue)
                if !listing.note.isEmpty { Text(listing.note).foregroundStyle(.secondary) }
            }
            .navigationTitle("Fonte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Catálogo de uma fonte

/// Lista de títulos de uma fonte nativa, com busca e paginação.
struct SourceCatalogView: View {
    @Environment(AppModel.self) private var model
    let sourceId: SourceID

    @State private var items: [SourceManga] = []
    @State private var page = 1
    @State private var hasNext = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var latest = false
    @State private var opening: String?
    @State private var opened: OpenedManga?

    private var source: (any MangaSource)? { model.registry.source(sourceId) }

    var body: some View {
        Group {
            if let errorMessage, items.isEmpty {
                VStack(spacing: 12) {
                    EmptyStateView(title: "Fonte indisponível", systemImage: "wifi.exclamationmark",
                                   message: errorMessage)
                    Button("Tentar novamente") { Task { await load(reset: true) } }.fyProminentButton()
                }
            } else if !isLoading && items.isEmpty {
                // Catálogo vazio ≠ fonte indisponível.
                EmptyStateView(title: "Nenhum título", systemImage: "tray",
                               message: !query.isEmpty ? "Nada encontrado para \"\(query)\"."
                                   : (sourceId == .local ? "Importe arquivos CBZ, ZIP, EPUB ou pastas pelo botão + da Biblioteca."
                                      : "Esta fonte não retornou títulos."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 12) {
                        ForEach(items) { item in
                            Button { Task { await open(item) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Color.clear
                                        .aspectRatio(0.72, contentMode: .fit)
                                        .overlay {
                                            CoverView(manga: item.toManga(sourceId: sourceId, isDemo: source?.kind == .demo))
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: FYMetrics.coverCornerRadius, style: .continuous))
                                        .overlay { if opening == item.key { ProgressView() } }
                                    Text(item.title).font(.caption.weight(.medium)).lineLimit(2)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                            .onAppear { if item == items.last && hasNext { Task { await load(reset: false) } } }
                        }
                    }
                    .padding(FYMetrics.screenPadding)
                    if isLoading { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(source?.name ?? sourceId.rawValue)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Pesquisar nesta fonte")
        .onSubmit(of: .search) { Task { await load(reset: true) } }
        .onChange(of: query) { _, new in if new.isEmpty { Task { await load(reset: true) } } }
        .toolbar {
            if source?.supportsLatest == true {
                ToolbarItem(placement: .topBarTrailing) {
                    Picker("Lista", selection: $latest) {
                        Text("Populares").tag(false)
                        Text("Recentes").tag(true)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .onChange(of: latest) { _, _ in Task { await load(reset: true) } }
        .task { if items.isEmpty { await load(reset: true) } }
        .navigationDestination(item: $opened) { MangaDetailView(mangaId: $0.id) }
    }

    private func load(reset: Bool) async {
        guard let source else {
            errorMessage = "Fonte não instalada."
            return
        }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        let next = reset ? 1 : page + 1
        do {
            let result: MangaListPage
            if !query.isEmpty {
                result = try await source.search(query: query, page: next)
            } else if latest {
                result = try await source.latest(page: next)
            } else {
                result = try await source.popular(page: next)
            }
            items = reset ? result.items : items + result.items.filter { n in !items.contains { $0.key == n.key } }
            page = next
            hasNext = result.hasNextPage
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Persiste o título localmente (sem adicionar à biblioteca) e abre os detalhes.
    private func open(_ item: SourceManga) async {
        opening = item.key
        defer { opening = nil }
        do {
            let (manga, _) = try await model.service.fetchAndStore(item, sourceId: sourceId)
            model.touch()
            opened = OpenedManga(id: manga.id)
        } catch {
            model.report(error)
        }
    }
}

struct OpenedManga: Hashable, Identifiable {
    let id: Int64
}

// MARK: - Migrar

struct MigrateView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [LibraryTitle] = []
    @State private var migrating: Manga?

    var body: some View {
        let groups = Dictionary(grouping: items, by: { $0.manga.sourceId })
        List {
            Section {
                Text("Mova um título para outra fonte mantendo categorias, capítulos lidos e marcadores.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(groups.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { sid in
                Section(model.registry.source(sid)?.name ?? "\(sid.rawValue) (não instalada)") {
                    ForEach(groups[sid] ?? []) { item in
                        Button {
                            migrating = item.manga
                        } label: {
                            HStack(spacing: 12) {
                                CoverView(manga: item.manga, cornerRadius: 6).frame(width: 36, height: 50)
                                Text(item.manga.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .overlay {
            if items.isEmpty {
                EmptyStateView(title: "Biblioteca vazia", systemImage: "arrow.left.arrow.right",
                               message: "Adicione títulos à biblioteca para poder migrá-los.")
            }
        }
        .task(id: model.dataVersion) { items = (try? model.store.library.items()) ?? [] }
        .sheet(item: $migrating) { MigrationSheet(manga: $0) }
    }
}

// MARK: - Idiomas

enum LanguageName {
    static func display(_ code: String) -> String {
        switch code {
        case "all": return "Multi"
        case "other": return "Outros"
        default:
            return Locale(identifier: "pt_BR").localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: "pt_BR"))
                ?? code
        }
    }
}
