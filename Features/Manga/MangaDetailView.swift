import SwiftUI
import FYDomain
import FYSources
import FYCore
import FYData
import FYServices

/// Detalhes de um título já salvo localmente (Biblioteca/Histórico).
struct MangaDetailView: View {
    @Environment(AppModel.self) private var model
    let mangaId: Int64

    @State private var manga: Manga?
    @State private var chapters: [Chapter] = []
    @State private var progress: [Int64: ReadingProgress] = [:]
    @State private var inLibrary = false
    @State private var reader: ReaderLaunch?
    @State private var newestFirst = true
    @State private var expandedSummary = false
    @State private var confirmDeleteFiles = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let manga {
                List {
                    Section { header(manga) }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    Section {
                        ForEach(orderedChapters) { chapterRow($0) }
                    } header: {
                        HStack {
                            Text("\(chapters.count) capítulos")
                            Spacer()
                            Button {
                                newestFirst.toggle()
                            } label: {
                                Label(newestFirst ? "Mais recentes primeiro" : "Mais antigos primeiro",
                                      systemImage: "arrow.up.arrow.down")
                                    .labelStyle(.iconOnly)
                            }
                            .accessibilityLabel("Inverter ordem dos capítulos")
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await refreshFromSource(manga) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(manga?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.dataVersion) { load() }
        .confirmationDialog("Excluir os arquivos importados?", isPresented: $confirmDeleteFiles,
                            titleVisibility: .visible) {
            Button("Excluir arquivos e progresso", role: .destructive) {
                if let manga { model.deleteLocalFiles(of: manga) }
                dismiss()
            }
        } message: {
            Text("As páginas são apagadas deste aparelho. O arquivo original (no app Arquivos) não é alterado.")
        }
        .fullScreenCover(item: $reader) { launch in
            ReaderView(launch: launch)
        }
    }

    private var orderedChapters: [Chapter] { newestFirst ? chapters.reversed() : chapters }

    private func load() {
        do {
            manga = try model.store.library.manga(id: mangaId)
            chapters = try model.store.chapters.chapters(mangaId: mangaId)
            inLibrary = try model.store.library.isInLibrary(mangaId: mangaId)
            progress = Dictionary(uniqueKeysWithValues: try model.store.progress.progress(mangaId: mangaId)
                .map { ($0.chapterId, $0) })
        } catch {
            model.report(error)
        }
    }

    @ViewBuilder
    private func header(_ manga: Manga) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Color.clear
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay { CoverView(manga: manga) }
                    .clipShape(RoundedRectangle(cornerRadius: FYMetrics.coverCornerRadius, style: .continuous))
                    .frame(width: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(manga.title).font(.title3.weight(.bold))
                    if let author = manga.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                    Label(manga.status.label, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let source = model.registry.source(manga.sourceId) {
                        Label(source.name, systemImage: "safari").font(.caption).foregroundStyle(.secondary)
                    }
                    if manga.isDemo {
                        Text("Conteúdo fictício de demonstração")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    toggleLibrary()
                } label: {
                    Label(inLibrary ? "Na biblioteca" : "Adicionar à biblioteca",
                          systemImage: inLibrary ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .fyProminentButton()

                if let next = nextChapterToRead {
                    Button {
                        open(next)
                    } label: {
                        Label(progress[next.id] == nil ? "Começar" : "Continuar", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .fySecondaryButton()
                }
            }
            .controlSize(.large)

            if manga.sourceId == .local {
                Button(role: .destructive) { confirmDeleteFiles = true } label: {
                    Label("Excluir arquivos importados", systemImage: "trash")
                }
                .font(.subheadline)
            }

            if let summary = manga.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .lineLimit(expandedSummary ? nil : 3)
                    .onTapGesture { withAnimation { expandedSummary.toggle() } }
            }
            if !manga.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(manga.genres, id: \.self) {
                            Text($0).font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(FYMetrics.screenPadding)
    }

    private var nextChapterToRead: Chapter? {
        chapters.first { !$0.isRead } ?? chapters.last
    }

    private func chapterRow(_ chapter: Chapter) -> some View {
        Button {
            open(chapter)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if chapter.isBookmarked {
                            Image(systemName: "bookmark.fill").foregroundStyle(FYColor.accent).font(.caption)
                        }
                        Text(chapter.name).font(.body)
                    }
                    HStack(spacing: 8) {
                        if let date = chapter.uploadDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let scan = chapter.scanlator { Text(scan) }
                        if let p = progress[chapter.id], !chapter.isRead, p.pageIndex > 0 {
                            Text("Página \(p.pageIndex + 1)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .foregroundStyle(chapter.isRead ? Color.secondary : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                model.mutate { try model.store.chapters.setRead([chapter.id], read: !chapter.isRead) }
            } label: {
                Label(chapter.isRead ? "Não lido" : "Lido", systemImage: chapter.isRead ? "eye.slash" : "eye")
            }
            .tint(FYColor.accent)
        }
        .swipeActions(edge: .trailing) {
            Button {
                model.mutate { try model.store.chapters.setBookmarked(chapter.id, !chapter.isBookmarked) }
            } label: {
                Label("Marcador", systemImage: chapter.isBookmarked ? "bookmark.slash" : "bookmark")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                let ids = chapters.prefix(while: { $0.id != chapter.id }).map(\.id) + [chapter.id]
                model.mutate { try model.store.chapters.setRead(ids, read: true) }
            } label: { Label("Marcar este e anteriores como lidos", systemImage: "checkmark.circle") }
        }
    }

    private func open(_ chapter: Chapter) {
        guard let manga else { return }
        reader = ReaderLaunch(manga: manga, chapters: chapters, chapterId: chapter.id)
    }

    private func toggleLibrary() {
        let wasIn = inLibrary
        model.mutate {
            if wasIn {
                try model.store.library.remove(mangaIds: [mangaId])
            } else {
                try model.store.library.add(mangaId: mangaId, categoryIds:
                    model.settings.defaultCategoryId.map { [$0] } ?? [])
            }
        }
        Haptics.success()
    }

    private func refreshFromSource(_ manga: Manga) async {
        do {
            try await model.service.fetchAndStore(SourceManga(key: manga.key, title: manga.title),
                                                  sourceId: manga.sourceId)
            model.touch()
        } catch {
            model.report(error)
        }
    }
}

/// Parâmetros para abrir o leitor.
struct ReaderLaunch: Identifiable {
    let manga: Manga
    let chapters: [Chapter]
    let chapterId: Int64
    var id: Int64 { chapterId }
}
