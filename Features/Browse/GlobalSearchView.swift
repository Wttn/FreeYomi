import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Fontes usadas por padrão na busca global: idioma do usuário + multi-idioma + fixadas.
@MainActor
func defaultSearchSources(_ model: AppModel, excluding: SourceID? = nil, all: Bool = false) -> [SourceID] {
    let preferred: Set<String> = ["pt-br", "pt", "all", "multi", model.settings.mangaDexLanguage.lowercased()]
    let pinned = Set(((try? model.store.sources.all()) ?? []).filter(\.isPinned).map(\.id))
    return model.registry.all
        .filter { $0.kind != .demo && $0.id != excluding }
        .filter { all || pinned.contains($0.id) || preferred.contains($0.language.lowercased()) }
        .sorted { (pinned.contains($0.id) ? 0 : 1, $0.name) < (pinned.contains($1.id) ? 0 : 1, $1.name) }
        .map(\.id)
}

/// Busca global: um termo em várias fontes ao mesmo tempo (como no Mihon/Tachimanga).
struct GlobalSearchView: View {
    @Environment(AppModel.self) private var model
    var initialQuery = ""

    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var searching = false
    @State private var allSources = false
    @State private var opening: String?
    @State private var opened: OpenedManga?

    var body: some View {
        List {
            Section {
                Toggle("Todas as fontes (não só do seu idioma e fixadas)", isOn: $allSources)
                    .font(.subheadline)
            }
            if searching { Section { HStack { ProgressView(); Text("Buscando…").foregroundStyle(.secondary) } } }
            ForEach(results) { r in
                Section(r.sourceName) {
                    if let error = r.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    } else if r.items.isEmpty {
                        Text("Nenhum resultado").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(r.items.prefix(15)) { item in
                                    Button { Task { await open(item, sourceId: r.sourceId) } } label: {
                                        SearchResultCard(item: item, sourceId: r.sourceId, loading: opening == item.key)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
            }
        }
        .navigationTitle("Busca global")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Título do mangá")
        .onSubmit(of: .search) { Task { await run() } }
        .onChange(of: allSources) { _, _ in if !query.isEmpty { Task { await run() } } }
        .onAppear {
            if query.isEmpty && !initialQuery.isEmpty {
                query = initialQuery
                Task { await run() }
            }
        }
        .navigationDestination(item: $opened) { MangaDetailView(mangaId: $0.id) }
        .overlay {
            if results.isEmpty && !searching {
                EmptyStateView(title: "Busque em todas as fontes", systemImage: "magnifyingglass",
                               message: "Digite um título. As fontes do servidor de extensões e o MangaDex são consultados ao mesmo tempo.")
            }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        results = []
        results = await model.service.globalSearch(q, sourceIds: defaultSearchSources(model, all: allSources))
        searching = false
    }

    private func open(_ item: SourceManga, sourceId: SourceID) async {
        opening = item.key
        defer { opening = nil }
        do {
            let (manga, _) = try await model.service.fetchAndStore(item, sourceId: sourceId)
            model.touch()
            opened = OpenedManga(id: manga.id)
        } catch { model.report(error) }
    }
}

struct SearchResultCard: View {
    let item: SourceManga
    let sourceId: SourceID
    var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .frame(width: 100, height: 142)
                .overlay { CoverView(manga: item.toManga(sourceId: sourceId, isDemo: false), cornerRadius: 8) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { if loading { ProgressView() } }
            Text(item.title).font(.caption).lineLimit(2).frame(width: 100, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Migração de um título para outra fonte.
struct MigrationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let manga: Manga

    @State private var query = ""
    @State private var results: [GlobalSearchResult] = []
    @State private var searching = false
    @State private var target: (SourceManga, SourceID)?
    @State private var options = MigrationOptions()
    @State private var migrating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        CoverView(manga: manga, cornerRadius: 6).frame(width: 44, height: 62)
                        VStack(alignment: .leading) {
                            Text(manga.title).font(.headline)
                            Text("Fonte atual: \(model.registry.source(manga.sourceId)?.name ?? manga.sourceId.rawValue)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if searching { Section { HStack { ProgressView(); Text("Procurando em outras fontes…") } } }
                ForEach(results) { r in
                    Section(r.sourceName) {
                        if let error = r.error {
                            Text(error).font(.caption).foregroundStyle(.orange)
                        } else if r.items.isEmpty {
                            Text("Nenhum resultado").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(r.items.prefix(6)) { item in
                                Button { target = (item, r.sourceId) } label: {
                                    HStack(spacing: 12) {
                                        CoverView(manga: item.toManga(sourceId: r.sourceId, isDemo: false), cornerRadius: 6)
                                            .frame(width: 36, height: 50)
                                        Text(item.title).foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Migrar")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Título na nova fonte")
            .onSubmit(of: .search) { Task { await search() } }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task {
                if query.isEmpty { query = manga.title; await search() }
            }
            .sheet(isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                confirmView.presentationDetents([.medium])
            }
        }
    }

    @ViewBuilder
    private var confirmView: some View {
        NavigationStack {
            Form {
                if let t = target {
                    Section {
                        LabeledContent("Destino", value: t.0.title)
                        LabeledContent("Fonte", value: model.registry.source(t.1)?.name ?? t.1.rawValue)
                    }
                }
                Section {
                    Toggle("Copiar categorias", isOn: $options.copyCategories)
                    Toggle("Copiar capítulos lidos e marcadores", isOn: $options.copyReadState)
                    Toggle("Remover o original da biblioteca", isOn: $options.removeOldFromLibrary)
                } footer: {
                    Text("O histórico do original é mantido. Capítulos são associados pelo número.")
                }
                Section {
                    Button {
                        Task { await migrate() }
                    } label: {
                        HStack { Text("Migrar"); if migrating { Spacer(); ProgressView() } }
                    }
                    .disabled(migrating)
                }
            }
            .navigationTitle("Confirmar migração")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        results = await model.service.globalSearch(q, sourceIds: defaultSearchSources(model, excluding: manga.sourceId))
        searching = false
    }

    private func migrate() async {
        guard let t = target else { return }
        let (item, sid) = t
        migrating = true
        defer { migrating = false }
        do {
            let new = try await model.service.migrate(mangaId: manga.id, to: item, sourceId: sid, options: options)
            model.touch()
            Haptics.success()
            target = nil
            dismiss()
            model.alertMessage = "\"\(manga.title)\" foi migrado para \(model.registry.source(sid)?.name ?? sid.rawValue) como \"\(new.title)\"."
        } catch {
            model.report(error)
        }
    }
}
