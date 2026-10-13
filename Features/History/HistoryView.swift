import SwiftUI
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Histórico — referência: captura "Histórico" (miniatura, título, capítulo,
/// tempo de leitura, data relativa e lixeira por linha; óculos, busca e
/// lixeira geral no topo).
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    @State private var items: [HistoryItem] = []
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var confirmClearAll = false
    @State private var pendingDelete: HistoryItem?
    @State private var reader: ReaderLaunch?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if items.isEmpty {
                    if !searchText.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        EmptyStateView(title: "Nada lido recentemente", systemImage: "clock",
                                       message: model.settings.incognitoMode
                                           ? "O modo anônimo está ativo: novas leituras não são registradas."
                                           : "Os capítulos que você ler aparecerão aqui.")
                    }
                } else {
                    List {
                        if model.settings.incognitoMode {
                            Label("Modo anônimo ativo — novas leituras não são registradas.",
                                  systemImage: "eyeglasses")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            HistoryRow(item: item,
                                       onOpen: { resume(item) },
                                       onDelete: { pendingDelete = item })
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Histórico")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Toggle(isOn: $model.settings.incognitoMode) {
                        Label("Modo anônimo", systemImage: "eyeglasses")
                    }
                    .toggleStyle(.button)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { isSearching = true } label: { Label("Pesquisar", systemImage: "magnifyingglass") }
                    Button { confirmClearAll = true } label: { Label("Limpar histórico", systemImage: "trash") }
                        .disabled(items.isEmpty)
                }
            }
            .searchable(text: $searchText, isPresented: $isSearching, prompt: "Pesquisar no histórico")
            .task(id: "\(model.dataVersion)|\(searchText)") { reload() }
            .confirmationDialog("Limpar todo o histórico?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                Button("Limpar histórico", role: .destructive) {
                    model.mutate { try model.store.history.clearAll() }
                }
            } message: {
                Text("O progresso de leitura dos capítulos é mantido.")
            }
            .confirmationDialog("Remover do histórico?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete) { item in
                Button("Remover este capítulo", role: .destructive) {
                    model.mutate { try model.store.history.delete(id: item.id) }
                }
                Button("Remover tudo de \(item.manga.title)", role: .destructive) {
                    model.mutate { try model.store.history.deleteAll(mangaId: item.manga.id) }
                }
            }
            .fullScreenCover(item: $reader) { ReaderView(launch: $0) }
        }
    }

    private func reload() {
        do {
            items = try model.store.history.recent(search: searchText)
        } catch {
            model.report(error)
        }
    }

    private func resume(_ item: HistoryItem) {
        do {
            let chapters = try model.store.chapters.chapters(mangaId: item.manga.id)
            reader = ReaderLaunch(manga: item.manga, chapters: chapters, chapterId: item.chapter.id)
        } catch {
            model.report(error)
        }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 14) {
                    CoverView(manga: item.manga, cornerRadius: FYMetrics.thumbnailCornerRadius)
                        .frame(width: FYMetrics.historyThumbSize.width * 1.35,
                               height: FYMetrics.historyThumbSize.height * 1.35)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.manga.title).font(.headline).lineLimit(1)
                        Text(item.chapter.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        if item.entry.durationSeconds >= 60 {
                            Label(Self.duration(item.entry.durationSeconds), systemImage: "book.closed")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Label(item.entry.readAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let p = item.progress, !p.isFinished, p.pageCount > 0 {
                            ProgressView(value: p.fraction)
                                .tint(FYColor.accent)
                                .frame(maxWidth: 160)
                                .accessibilityLabel("Progresso")
                                .accessibilityValue("Página \(p.pageIndex + 1) de \(p.pageCount)")
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remover \(item.manga.title) do histórico")
        }
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
    }

    static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
