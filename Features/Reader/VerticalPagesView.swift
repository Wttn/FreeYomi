import SwiftUI
import UIKit
import FYDomain

/// Leitor dos modos verticais (vertical contínuo, webtoon e paginado vertical)
/// implementado em UIKit.
///
/// Por que UIKit: a versão com `LazyVStack` + rastreamento de geometria do
/// SwiftUI travava a thread principal ao chegar ao fim do capítulo. Aqui o
/// layout é calculado uma vez a partir da proporção de cada página e as
/// imagens são carregadas/descartadas explicitamente, sem ciclos de layout.
///
/// Bônus: zoom por pinça/toque duplo também no modo vertical e restauração
/// exata da posição (página + deslocamento dentro dela).
struct VerticalPagesView: UIViewRepresentable {
    let pages: [Page]
    /// Paginado vertical: cada página ocupa a tela e a rolagem para em cada uma.
    let paged: Bool
    let spacing: CGFloat
    let request: ReaderView.ScrollRequest?
    let onPosition: (Int, Double) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPosition: onPosition, onTap: onTap) }

    func makeUIView(context: Context) -> VerticalPagesScrollView {
        let view = VerticalPagesScrollView(coordinator: context.coordinator)
        view.configure(pages: pages, paged: paged, spacing: spacing)
        if let request { view.requestScroll(page: request.page, offset: request.offset, id: request.id) }
        return view
    }

    func updateUIView(_ view: VerticalPagesScrollView, context: Context) {
        context.coordinator.onPosition = onPosition
        context.coordinator.onTap = onTap
        view.configure(pages: pages, paged: paged, spacing: spacing)
        if let request { view.requestScroll(page: request.page, offset: request.offset, id: request.id) }
    }

    static func dismantleUIView(_ view: VerticalPagesScrollView, coordinator: Coordinator) {
        view.cancelAll()
    }

    final class Coordinator: NSObject {
        var onPosition: (Int, Double) -> Void
        var onTap: () -> Void
        init(onPosition: @escaping (Int, Double) -> Void, onTap: @escaping () -> Void) {
            self.onPosition = onPosition
            self.onTap = onTap
        }
    }
}

final class VerticalPagesScrollView: UIScrollView, UIScrollViewDelegate {
    private weak var coordinator: VerticalPagesView.Coordinator?
    private let content = UIView()
    private var pages: [Page] = []
    private var imageViews: [UIImageView] = []
    private var placeholders: [UIImageView] = []
    private var aspects: [CGFloat] = []          // altura / largura
    private var frames: [CGRect] = []            // em coordenadas do `content` (sem zoom)
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var paged = false
    private var spacing: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    private var laidOutHeight: CGFloat = 0
    private var pendingScroll: (page: Int, offset: Double)?
    private var lastRequestId: UUID?
    private var lastReported: (Int, Double) = (-1, -1)
    /// Páginas mantidas carregadas ao redor da visível.
    private let keepRange = 2

    init(coordinator: VerticalPagesView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        minimumZoomScale = 1
        maximumZoomScale = 3
        bouncesZoom = true
        decelerationRate = .normal
        addSubview(content)

        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    // MARK: Configuração

    func configure(pages newPages: [Page], paged newPaged: Bool, spacing newSpacing: CGFloat) {
        let samePages = newPages.map(\.image) == pages.map(\.image)
        guard !samePages || newPaged != paged || newSpacing != spacing else { return }
        cancelAll()
        pages = newPages
        paged = newPaged
        spacing = newSpacing
        isPagingEnabled = newPaged
        imageViews.forEach { $0.removeFromSuperview() }
        placeholders.forEach { $0.removeFromSuperview() }
        imageViews = []
        placeholders = []
        aspects = pages.map { ImagePipeline.shared.knownAspect($0.image) ?? 1.42 }
        for (i, _) in pages.enumerated() {
            let placeholder = UIImageView(image: UIImage(systemName: "photo"))
            placeholder.tintColor = .darkGray
            placeholder.contentMode = .center
            placeholder.backgroundColor = UIColor(white: 0.1, alpha: 1)
            content.addSubview(placeholder)
            placeholders.append(placeholder)

            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            iv.isAccessibilityElement = true
            iv.accessibilityTraits = .image
            iv.accessibilityLabel = "Página \(i + 1) de \(pages.count)"
            content.addSubview(iv)
            imageViews.append(iv)
        }
        laidOutWidth = 0
        lastReported = (-1, -1)
        setZoomScale(1, animated: false)
        setNeedsLayout()
    }

    func requestScroll(page: Int, offset: Double, id: UUID) {
        guard id != lastRequestId else { return }
        lastRequestId = id
        pendingScroll = (page, offset)
        setNeedsLayout()
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, !pages.isEmpty else { return }
        if bounds.width != laidOutWidth || bounds.height != laidOutHeight {
            let anchor = laidOutWidth > 0 ? currentPosition() : nil
            relayout()
            if pendingScroll == nil, let anchor { pendingScroll = anchor }
        }
        if let target = pendingScroll {
            pendingScroll = nil
            scroll(toPage: target.page, offset: target.offset)
        }
        centerHorizontally()
    }

    private func relayout() {
        // O layout é calculado sempre sem zoom; o zoom é só uma transformação do `content`.
        if zoomScale != 1 { setZoomScale(1, animated: false) }
        laidOutWidth = bounds.width
        laidOutHeight = bounds.height
        let width = bounds.width
        var y: CGFloat = 0
        frames = []
        for i in pages.indices {
            let h = paged ? bounds.height : (width * aspects[i]).rounded()
            let f = CGRect(x: 0, y: y, width: width, height: h)
            frames.append(f)
            imageViews[i].frame = f
            placeholders[i].frame = f
            y += h + (paged ? 0 : spacing)
        }
        let total = paged ? y : max(0, y - spacing)
        content.frame = CGRect(x: 0, y: 0, width: width, height: total)
        contentSize = content.frame.size
        updateLoadedPages()
    }

    private func scroll(toPage page: Int, offset: Double) {
        guard frames.indices.contains(page) else { return }
        let f = frames[page]
        let y = (f.minY + CGFloat(min(max(offset, 0), 1)) * f.height) * zoomScale
        let maxY = max(0, contentSize.height - bounds.height)
        contentOffset = CGPoint(x: contentOffset.x, y: min(max(0, y), maxY))
        updateLoadedPages()
        // Pode ocorrer durante uma atualização do SwiftUI: avisa no próximo ciclo.
        DispatchQueue.main.async { [weak self] in self?.reportPosition(force: true) }
    }

    private func centerHorizontally() {
        let insetX = max(0, (bounds.width - contentSize.width) / 2)
        if contentInset.left != insetX { contentInset = UIEdgeInsets(top: 0, left: insetX, bottom: 0, right: insetX) }
    }

    // MARK: Posição

    /// Página que cruza o topo da tela e o deslocamento (0–1) dentro dela.
    private func currentPosition() -> (page: Int, offset: Double)? {
        guard !frames.isEmpty else { return nil }
        let top = (contentOffset.y + 1) / max(zoomScale, 0.01)
        // Busca binária: as molduras estão em ordem crescente de y.
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].minY <= top { lo = mid } else { hi = mid - 1 }
        }
        let f = frames[lo]
        let offset = f.height > 0 ? Double(min(max((top - f.minY) / f.height, 0), 1)) : 0
        return (lo, offset)
    }

    private func reportPosition(force: Bool = false) {
        guard let pos = currentPosition() else { return }
        if force || pos.page != lastReported.0 || abs(pos.offset - lastReported.1) > 0.02 {
            lastReported = (pos.page, pos.offset)
            coordinator?.onPosition(pos.page, pos.offset)
        }
    }

    // MARK: Carregamento sob demanda

    private func visibleRange() -> ClosedRange<Int>? {
        guard !frames.isEmpty else { return nil }
        let top = contentOffset.y / max(zoomScale, 0.01)
        let bottom = (contentOffset.y + bounds.height) / max(zoomScale, 0.01)
        guard let first = frames.firstIndex(where: { $0.maxY >= top }) else { return nil }
        let last = frames.lastIndex(where: { $0.minY <= bottom }) ?? first
        return min(first, last)...max(first, last)
    }

    private func updateLoadedPages() {
        guard let visible = visibleRange() else { return }
        let keep = max(0, visible.lowerBound - keepRange)...min(pages.count - 1, visible.upperBound + keepRange)
        for i in pages.indices {
            if keep.contains(i) {
                load(i)
            } else {
                // Libera a memória de páginas distantes.
                tasks[i]?.cancel()
                tasks[i] = nil
                if imageViews[i].image != nil { imageViews[i].image = nil }
                placeholders[i].isHidden = false
            }
        }
    }

    private func load(_ i: Int) {
        guard imageViews[i].image == nil, tasks[i] == nil else { return }
        let ref = pages[i].image
        let width = ImagePipeline.pixelWidth(forPoints: max(bounds.width, 320))
        tasks[i] = Task { @MainActor [weak self] in
            defer { self?.tasks[i] = nil }
            do {
                let image = try await ImagePipeline.shared.image(for: ref, targetPixelWidth: width)
                guard let self, !Task.isCancelled, self.imageViews.indices.contains(i),
                      self.pages.indices.contains(i), self.pages[i].image == ref else { return }
                self.imageViews[i].image = image
                self.placeholders[i].isHidden = true
                // Proporção desconhecida (ex.: imagem remota): ajusta preservando a posição.
                let real = image.size.height / max(image.size.width, 1)
                if !self.paged, self.zoomScale <= 1.01, abs(real - self.aspects[i]) > 0.01 {
                    let anchor = self.currentPosition()
                    self.aspects[i] = real
                    self.relayout()
                    if let anchor { self.scroll(toPage: anchor.page, offset: anchor.offset) }
                }
            } catch {
                guard let self, !Task.isCancelled, self.placeholders.indices.contains(i) else { return }
                self.placeholders[i].image = UIImage(systemName: "exclamationmark.triangle")
                self.placeholders[i].accessibilityLabel = "Página \(i + 1) indisponível"
            }
        }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateLoadedPages()
        reportPosition()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerHorizontally()
        isPagingEnabled = paged && zoomScale <= minimumZoomScale + 0.01
    }

    // MARK: Gestos

    @objc private func handleSingleTap() { coordinator?.onTap() }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        let animated = !UIAccessibility.isReduceMotionEnabled
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: animated)
        } else {
            let p = g.location(in: content)
            let target: CGFloat = 2
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                            width: size.width, height: size.height), animated: animated)
        }
    }
}
