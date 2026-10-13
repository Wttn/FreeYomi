import SwiftUI
import FYCore
import FYDomain
import FYData
import FYSources
import FYServices

/// Leitor de capítulos.
///
/// - Modos: paginado D→E e E→D, paginado vertical, vertical contínuo e webtoon.
/// - Modos paginados: zoom por pinça/toque duplo (`ZoomablePageView`) e
///   escalas página inteira / largura / altura / original.
/// - Pipeline de imagens com redução de resolução, cache e pré-carregamento
///   das próximas páginas; pré-carga cancelada ao sair.
/// - Progresso salvo automaticamente: página atual e, nos modos verticais,
///   o deslocamento dentro da página (0–1), também em segundo plano.
struct ReaderView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let launch: ReaderLaunch

    @State private var chapterIndex: Int
    @State private var pages: [Page] = []
    @State private var current = 0
    @State private var scrollOffset: Double = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showControls = true
    @State private var mode: ReadingMode = .pagedRightToLeft
    @State private var scale: PageScale = .fitScreen
    @State private var sessionStart = Date()
    @State private var didRestorePosition = false
    @State private var scrollRequest: ScrollRequest?
    @State private var pendingSave: Task<Void, Never>?
    @State private var isZoomed = false
    @State private var originalBrightness: CGFloat?

    /// Pedido de rolagem para os modos verticais (restaurar posição, barra de páginas).
    struct ScrollRequest: Equatable {
        let id = UUID()
        let page: Int
        let offset: Double
    }

    init(launch: ReaderLaunch) {
        self.launch = launch
        _chapterIndex = State(initialValue: launch.chapters.firstIndex { $0.id == launch.chapterId } ?? 0)
    }

    private var chapter: Chapter? {
        launch.chapters.indices.contains(chapterIndex) ? launch.chapters[chapterIndex] : nil
    }

    private var screenWidth: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds.width ?? 390
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
        .onChange(of: current) { _, _ in
            saveProgress()
            prefetchAhead()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveProgress(); closeSession() }
        }
        .onAppear {
            mode = model.settings.reader.mode
            scale = model.settings.reader.scale
            UIApplication.shared.isIdleTimerDisabled = model.settings.reader.keepScreenOn
            applyBrightness()
        }
        .onDisappear {
            pendingSave?.cancel()
            saveProgress()
            closeSession()
            ImagePipeline.shared.cancelPrefetch()
            UIApplication.shared.isIdleTimerDisabled = false
            restoreBrightness()
        }
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var readerContent: some View {
        switch mode {
        case .pagedRightToLeft, .pagedLeftToRight:
            horizontalPager
        case .pagedVertical:
            verticalReader(paging: true, spacing: 0)
        case .continuousVertical:
            verticalReader(paging: false, spacing: 6)
        case .webtoon:
            verticalReader(paging: false, spacing: 0)
        }
    }

    private var horizontalPager: some View {
        // Em D→E a ordem é invertida: a página 1 fica à direita e o gesto
        // natural de "virar a página" de um mangá impresso leva à próxima.
        let ordered = mode == .pagedRightToLeft ? Array(pages.reversed()) : pages
        return TabView(selection: $current) {
            ForEach(ordered) { page in
                PagedReaderPage(page: page, scale: scale, pointWidth: screenWidth,
                                onTap: { handleTap(relativeX: $0) },
                                onZoomChange: { isZoomed = $0 })
                    .tag(page.index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Modos verticais: leitor em UIKit (`VerticalPagesView`), com zoom e posição exata.
    private func verticalReader(paging: Bool, spacing: CGFloat) -> some View {
        VerticalPagesView(pages: pages, paged: paging, spacing: spacing, request: scrollRequest,
                          onPosition: { page, offset in updatePosition(page, offset: offset) },
                          onTap: { toggleControls() })
    }

    /// Posição informada pelo leitor vertical (página no topo + deslocamento).
    private func updatePosition(_ index: Int, offset: Double) {
        guard didRestorePosition else { return }
        if current != index { current = index }
        if abs(offset - scrollOffset) > 0.02 {
            scrollOffset = offset
            scheduleSave()
        }
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
                    scrollRequest = ScrollRequest(page: current, offset: 0)
                })) {
                ForEach(ReadingMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if mode == .pagedLeftToRight || mode == .pagedRightToLeft {
                Picker("Escala", selection: Binding(
                    get: { scale },
                    set: { new in
                        scale = new
                        model.settings.reader.scale = new
                    })) {
                    ForEach(PageScale.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
        } label: {
            Image(systemName: "book.pages")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .fyGlass(in: Circle(), interactive: true)
        }
        .accessibilityLabel("Modo de leitura e escala")
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
                                scrollRequest = ScrollRequest(page: idx, offset: 0)
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
        guard settings.tapZonesEnabled, mode.isPaged, mode != .pagedVertical, !isZoomed else {
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
        saveProgress()
        closeSession()
        ImagePipeline.shared.cancelPrefetch()
        chapterIndex = target
    }

    private func prefetchAhead() {
        let n = model.settings.reader.preloadPageCount
        let refs = ReaderNavigation.preloadIndices(current: current, count: n, pageCount: pages.count)
            .map { pages[$0].image }
        ImagePipeline.shared.prefetch(refs, targetPixelWidth: ImagePipeline.pixelWidth(forPoints: screenWidth))
    }

    private func loadChapter() async {
        guard let chapter else { return }
        isLoading = true
        errorMessage = nil
        didRestorePosition = false
        sessionStart = Date()
        isZoomed = false
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
            await ImagePipeline.shared.preloadAspects(loaded)
            var start = 0
            var offset = 0.0
            if let saved = try? model.store.progress.progress(chapterId: chapter.id), !saved.isFinished {
                start = min(saved.pageIndex, loaded.count - 1)
                offset = saved.scrollOffset
            }
            pages = loaded
            current = start
            scrollOffset = offset
            scrollRequest = ScrollRequest(page: start, offset: offset)
            didRestorePosition = true
            if !model.settings.incognitoMode {
                try? model.store.history.record(mangaId: launch.manga.id, chapterId: chapter.id)
            }
            saveProgress()
            prefetchAhead()
        } catch {
            if (error as? FYError) == .cancelled || error is CancellationError { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Salva o deslocamento depois de 1 s sem rolagem (evita gravar a cada quadro).
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { saveProgress() }
        }
    }

    private func saveProgress() {
        guard didRestorePosition, !model.settings.incognitoMode, let chapter, !pages.isEmpty else { return }
        let finished = current >= pages.count - 1 && (mode.isPaged || scrollOffset > 0.85 || pages.count == 1)
        let offset = mode.isPaged && mode != .pagedVertical ? 0 : scrollOffset
        try? model.store.progress.save(ReadingProgress(chapterId: chapter.id, mangaId: launch.manga.id,
                                                       pageIndex: current, pageCount: pages.count,
                                                       scrollOffset: offset, isFinished: finished))
    }

    /// Registra o tempo de leitura do capítulo atual no histórico.
    private func closeSession() {
        guard let chapter, !model.settings.incognitoMode, didRestorePosition else { return }
        let seconds = Int(Date().timeIntervalSince(sessionStart))
        try? model.store.history.record(mangaId: launch.manga.id, chapterId: chapter.id, addingSeconds: seconds)
        sessionStart = Date()
        model.touch()
    }

    // MARK: - Brilho

    private var screen: UIScreen? { (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen }

    private func applyBrightness() {
        guard model.settings.reader.useCustomBrightness, let screen else { return }
        originalBrightness = screen.brightness
        screen.brightness = CGFloat(model.settings.reader.customBrightness)
    }

    private func restoreBrightness() {
        if let original = originalBrightness, let screen { screen.brightness = original }
        originalBrightness = nil
    }
}

// MARK: - Páginas

/// Página dos modos paginados: demo (desenhada) ou imagem com zoom.
struct PagedReaderPage: View {
    let page: Page
    let scale: PageScale
    let pointWidth: CGFloat
    let onTap: (Double) -> Void
    let onZoomChange: (Bool) -> Void

    @State private var image: UIImage?
    @State private var failed: String?
    @State private var attempt = 0

    var body: some View {
        GeometryReader { geo in
            Group {
                if case .demo(let seed, let label, let ratio) = page.image {
                    DemoPageView(seed: seed, label: label, aspectRatio: ratio)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { location in onTap(geo.size.width > 0 ? location.x / geo.size.width : 0.5) }
                } else if let image {
                    ZoomablePageView(image: image, scale: scale, onTap: onTap, onZoomChange: onZoomChange)
                } else if let failed {
                    VStack(spacing: 12) {
                        PageErrorView(index: page.index)
                        Text(failed).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Tentar novamente") { self.failed = nil; attempt += 1 }.fySecondaryButton()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { location in onTap(geo.size.width > 0 ? location.x / geo.size.width : 0.5) }
                } else {
                    ProgressView().tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { location in onTap(geo.size.width > 0 ? location.x / geo.size.width : 0.5) }
                }
            }
        }
        .task(id: "\(attempt)|\(page.image.hashValue)") {
            if case .demo = page.image { return }
            do {
                image = try await ImagePipeline.shared.image(
                    for: page.image, targetPixelWidth: ImagePipeline.pixelWidth(forPoints: pointWidth))
            } catch {
                if !Task.isCancelled { failed = error.localizedDescription }
            }
        }
        .onDisappear { image = nil }
    }
}
