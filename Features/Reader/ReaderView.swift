import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Leitor (versão inicial da Fase 1).
///
/// Implementado: paginado D→E e E→D, paginado vertical, vertical contínuo e
/// webtoon; zonas de toque; barra de progresso; navegação entre capítulos;
/// salvamento automático do progresso e histórico; manter tela ativa.
/// Pendente (Fase 2): zoom por gesto, ajuste à largura/altura, pipeline de
/// imagens com cache em disco e pré-carregamento explícito.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let launch: ReaderLaunch

    @State private var chapterIndex: Int
    @State private var pages: [Page] = []
    @State private var current = 0
    @State private var scrolledID: Int?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var mode: ReadingMode = .pagedRightToLeft
    @State private var sessionStart = Date()
    @State private var didRestorePosition = false

    init(launch: ReaderLaunch) {
        self.launch = launch
        _chapterIndex = State(initialValue: launch.chapters.firstIndex { $0.id == launch.chapterId } ?? 0)
    }

    private var chapter: Chapter? {
        launch.chapters.indices.contains(chapterIndex) ? launch.chapters[chapterIndex] : nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if isLoading {
                ProgressView().tint(.white)
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                readerContent.ignoresSafeArea()
            }
            if showControls { controls.transition(.opacity) }
            else if model.settings.reader.showPageNumber && !pages.isEmpty { pageIndicator }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .task(id: chapterIndex) { await loadChapter() }
        .onChange(of: current) { _, _ in saveProgress() }
        .onChange(of: scrolledID) { _, new in
            if let new, new != current { current = new }
        }
        .onAppear {
            mode = model.settings.reader.mode
            UIApplication.shared.isIdleTimerDisabled = model.settings.reader.keepScreenOn
        }
        .onDisappear {
            closeSession()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var readerContent: some View {
        GeometryReader { geo in
            Group {
                switch mode {
                case .pagedRightToLeft, .pagedLeftToRight:
                    horizontalPager
                case .pagedVertical:
                    verticalScroller(paging: true, spacing: 0)
                case .continuousVertical:
                    verticalScroller(paging: false, spacing: 6)
                case .webtoon:
                    verticalScroller(paging: false, spacing: 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleTap(relativeX: geo.size.width > 0 ? location.x / geo.size.width : 0.5)
            }
        }
    }

    private var horizontalPager: some View {
        // Em D→E a ordem é invertida: a página 1 fica à direita e o gesto
        // natural de "virar a página" de um mangá impresso leva à próxima.
        let ordered = mode == .pagedRightToLeft ? Array(pages.reversed()) : pages
        return TabView(selection: $current) {
            ForEach(ordered) { page in
                PageImageView(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(page.index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    @ViewBuilder
    private func verticalScroller(paging: Bool, spacing: CGFloat) -> some View {
        if paging {
            verticalScrollView(paging: true, spacing: spacing).scrollTargetBehavior(.paging)
        } else {
            verticalScrollView(paging: false, spacing: spacing)
        }
    }

    private func verticalScrollView(paging: Bool, spacing: CGFloat) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: spacing) {
                ForEach(pages) { page in
                    Group {
                        if paging {
                            PageImageView(page: page)
                                .containerRelativeFrame([.horizontal, .vertical])
                        } else {
                            PageImageView(page: page)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .id(page.index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrolledID, anchor: .top)
        .scrollIndicators(.hidden)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            HStack {
                Button("Tentar novamente") { Task { await loadChapter() } }.fyProminentButton()
                Button("Fechar") { dismiss() }.fySecondaryButton()
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    // MARK: - Controles

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                GlassIconButton(systemImage: "xmark", label: "Fechar leitor") { dismiss() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(launch.manga.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(chapter?.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fyGlass(in: Capsule())
                modeMenu
            }
            .padding(.horizontal, 12)

            Spacer()

            HStack(spacing: 10) {
                GlassIconButton(systemImage: "backward.end.fill", label: "Capítulo anterior") { goChapter(-1) }
                    .disabled(chapterIndex == 0)
                    .opacity(chapterIndex == 0 ? 0.4 : 1)
                progressBar
                GlassIconButton(systemImage: "forward.end.fill", label: "Próximo capítulo") { goChapter(+1) }
                    .disabled(chapterIndex >= launch.chapters.count - 1)
                    .opacity(chapterIndex >= launch.chapters.count - 1 ? 0.4 : 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
    }

    private var modeMenu: some View {
        Menu {
            Picker("Modo de leitura", selection: Binding(
                get: { mode },
                set: { new in
                    mode = new
                    model.settings.reader.mode = new
                    scrolledID = current
                })) {
                ForEach(ReadingMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        } label: {
            Image(systemName: "book.pages")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .fyGlass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("Modo de leitura")
    }

    @ViewBuilder
    private var progressBar: some View {
        HStack(spacing: 10) {
            Text("\(min(current + 1, max(pages.count, 1)))")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 22)
            if pages.count > 1 {
                Slider(
                    value: Binding(
                        get: { Double(current) },
                        set: { v in
                            let idx = Int(v.rounded())
                            if idx != current {
                                current = idx
                                scrolledID = idx
                            }
                        }),
                    in: 0...Double(pages.count - 1),
                    step: 1
                )
                .environment(\.layoutDirection, mode == .pagedRightToLeft ? .rightToLeft : .leftToRight)
                .accessibilityLabel("Página")
                .accessibilityValue("\(current + 1) de \(pages.count)")
            } else {
                Spacer()
            }
            Text("\(pages.count)")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 22)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .fyGlass(in: Capsule())
    }

    private var pageIndicator: some View {
        VStack {
            Spacer()
            Text("\(current + 1) / \(pages.count)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 4)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Ações

    private func handleTap(relativeX: Double) {
        let settings = model.settings.reader
        guard settings.tapZonesEnabled, mode.isPaged, mode != .pagedVertical else {
            toggleControls()
            return
        }
        let zone = ReaderNavigation.zone(forRelativeX: relativeX, mode: mode, invert: settings.invertTapZones)
        if zone == .menu { toggleControls(); return }
        if let target = ReaderNavigation.target(from: current, zone: zone, pageCount: pages.count) {
            if reduceMotion { current = target } else { withAnimation(.easeOut(duration: 0.2)) { current = target } }
        } else {
            goChapter(zone == .next ? +1 : -1)
        }
    }

    private func toggleControls() {
        if reduceMotion { showControls.toggle() } else { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }
    }

    private func goChapter(_ delta: Int) {
        let target = chapterIndex + delta
        guard launch.chapters.indices.contains(target) else { return }
        closeSession()
        chapterIndex = target
    }

    private func loadChapter() async {
        guard let chapter else { return }
        isLoading = true
        errorMessage = nil
        didRestorePosition = false
        sessionStart = Date()
        defer { isLoading = false }

        guard let source = model.registry.source(launch.manga.sourceId) else {
            errorMessage = "A fonte deste título não está disponível neste aparelho."
            return
        }
        do {
            let loaded = try await source.pages(mangaKey: launch.manga.key, chapterKey: chapter.key)
            guard !Task.isCancelled else { return }
            guard !loaded.isEmpty else {
                errorMessage = "Este capítulo não tem páginas."
                return
            }
            var start = 0
            if let saved = try? model.store.progress.progress(chapterId: chapter.id), !saved.isFinished {
                start = min(saved.pageIndex, loaded.count - 1)
            }
            pages = loaded
            current = start
            scrolledID = start
            didRestorePosition = true
            if !model.settings.incognitoMode {
                try? model.store.history.record(mangaId: launch.manga.id, chapterId: chapter.id)
            }
            saveProgress()
        } catch {
            if (error as? FYError) == .cancelled || error is CancellationError { return }
            errorMessage = error.localizedDescription
        }
    }

    private func saveProgress() {
        guard didRestorePosition, !model.settings.incognitoMode, let chapter, !pages.isEmpty else { return }
        let finished = current >= pages.count - 1
        try? model.store.progress.save(ReadingProgress(chapterId: chapter.id, mangaId: launch.manga.id,
                                                       pageIndex: current, pageCount: pages.count,
                                                       isFinished: finished))
    }

    /// Registra o tempo de leitura do capítulo atual no histórico.
    private func closeSession() {
        guard let chapter, !model.settings.incognitoMode, didRestorePosition else { return }
        let seconds = Int(Date().timeIntervalSince(sessionStart))
        try? model.store.history.record(mangaId: launch.manga.id, chapterId: chapter.id, addingSeconds: seconds)
        sessionStart = Date()
        model.touch()
    }
}
