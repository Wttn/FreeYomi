import SwiftUI
import FYDomain
import FYCore
import FYData
import FYSources
import FYServices

/// Atualizações — consulta capítulos novos nas fontes dos títulos da biblioteca.
/// Agendamento em segundo plano (BGAppRefreshTask) fica para a Fase 4.
struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var reader: ReaderLaunch?

    var body: some View {
        NavigationStack {
            List {
                if let report = model.lastRefresh {
                    Section {
                        LabeledContent("Última verificação",
                                       value: (report.finishedAt ?? report.startedAt)
                                           .formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Títulos verificados", value: "\(report.updated)")
                        if report.skipped > 0 {
                            LabeledContent("Ignorados (concluídos)", value: "\(report.skipped)")
                        }
                    }
                    if !report.failures.isEmpty {
                        Section("Falhas") {
                            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.0).font(.subheadline.weight(.semibold))
                                    Text(failure.1).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if report.newChapters.isEmpty {
                        Section {
                            Text("Nenhum capítulo novo encontrado.").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(Array(report.newChapters.enumerated()), id: \.offset) { _, entry in
                            Section(entry.0.title) {
                                ForEach(entry.1) { chapter in
                                    Button {
                                        open(manga: entry.0, chapter: chapter)
                                    } label: {
                                        HStack {
                                            CoverView(manga: entry.0, cornerRadius: 6).frame(width: 36, height: 50)
                                            VStack(alignment: .leading) {
                                                Text(chapter.name)
                                                Text(model.registry.source(entry.0.sourceId)?.name ?? entry.0.sourceId.rawValue)
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .swipeActions {
                                        Button("Lido") {
                                            model.mutate { try model.store.chapters.setRead([chapter.id], read: true) }
                                        }
                                        .tint(FYColor.accent)
                                    }
                                }
                            }
                        }
                    }
                } else if !model.isRefreshing {
                    EmptyStateView(title: "Nenhuma verificação ainda", systemImage: "bolt",
                                   message: "Toque em atualizar ou puxe a lista para procurar capítulos novos nas fontes compatíveis.")
                        .listRowBackground(Color.clear)
                }
            }
            .overlay { if model.isRefreshing { ProgressView("Verificando…").padding().fyGlass(in: RoundedRectangle(cornerRadius: 16)) } }
            .navigationTitle("Atualizações")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshLibrary() }
                    } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                    .disabled(model.isRefreshing)
                }
            }
            .refreshable { await model.refreshLibrary() }
            .fullScreenCover(item: $reader) { ReaderView(launch: $0) }
        }
    }

    private func open(manga: Manga, chapter: Chapter) {
        guard let chapters = try? model.store.chapters.chapters(mangaId: manga.id) else { return }
        reader = ReaderLaunch(manga: manga, chapters: chapters, chapterId: chapter.id)
    }
}
