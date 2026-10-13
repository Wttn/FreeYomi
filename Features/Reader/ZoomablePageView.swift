import SwiftUI
import UIKit
import FYDomain

/// Página com zoom por pinça e toque duplo, baseada em `UIScrollView`
/// (o componente nativo de zoom do iOS).
///
/// - Escalas: página inteira, ajuste à largura (rola na vertical), ajuste à
///   altura (rola na horizontal) e tamanho original.
/// - Sem zoom, o conteúdo não consome gestos horizontais: o deslize de página
///   do leitor continua funcionando. Com zoom, o arraste move a imagem.
/// - Toque simples é repassado com a posição horizontal relativa (zonas de toque).
struct ZoomablePageView: UIViewRepresentable {
    let image: UIImage
    let scale: PageScale
    let onTap: (Double) -> Void
    var onZoomChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onZoomChange: onZoomChange) }

    func makeUIView(context: Context) -> PageScrollView {
        let view = PageScrollView()
        view.delegate = context.coordinator
        view.setup(coordinator: context.coordinator)
        view.configure(image: image, scale: scale)
        return view
    }

    func updateUIView(_ view: PageScrollView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onZoomChange = onZoomChange
        view.configure(image: image, scale: scale)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var onTap: (Double) -> Void
        var onZoomChange: ((Bool) -> Void)?
        private var wasZoomed = false

        init(onTap: @escaping (Double) -> Void, onZoomChange: ((Bool) -> Void)?) {
            self.onTap = onTap
            self.onZoomChange = onZoomChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PageScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PageScrollView)?.centerContent()
            let zoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            if zoomed != wasZoomed {
                wasZoomed = zoomed
                onZoomChange?(zoomed)
            }
        }

        @objc func handleSingleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView, sv.bounds.width > 0 else { return }
            // Posição dentro da área visível (descontando a rolagem).
            let x = g.location(in: sv).x - sv.contentOffset.x
            onTap(Double(min(max(x / sv.bounds.width, 0), 1)))
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? PageScrollView else { return }
            if sv.zoomScale > sv.minimumZoomScale + 0.01 {
                sv.setZoomScale(sv.minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
            } else {
                let point = g.location(in: sv.imageView)
                let target = min(sv.maximumZoomScale, sv.minimumZoomScale * 2.5)
                let size = CGSize(width: sv.bounds.width / target, height: sv.bounds.height / target)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                sv.zoom(to: rect, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
}

final class PageScrollView: UIScrollView {
    let imageView = UIImageView()
    private var currentImage: UIImage?
    private var currentScale: PageScale = .fitScreen
    private var lastBounds: CGSize = .zero

    func setup(coordinator: ZoomablePageView.Coordinator) {
        backgroundColor = .black
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleToFill
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        imageView.accessibilityLabel = "Página"
        addSubview(imageView)

        let double = UITapGestureRecognizer(target: coordinator, action: #selector(ZoomablePageView.Coordinator.handleDoubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: coordinator, action: #selector(ZoomablePageView.Coordinator.handleSingleTap(_:)))
        single.require(toFail: double)
        addGestureRecognizer(single)
    }

    func configure(image: UIImage, scale: PageScale) {
        guard image !== currentImage || scale != currentScale else { return }
        currentImage = image
        currentScale = scale
        imageView.image = image
        lastBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = currentImage, bounds.width > 0, bounds.height > 0, bounds.size != lastBounds else {
            centerContent()
            return
        }
        lastBounds = bounds.size
        zoomScale = 1
        let imgSize = image.size
        let base: CGSize
        switch currentScale {
        case .fitScreen:
            let r = min(bounds.width / imgSize.width, bounds.height / imgSize.height)
            base = CGSize(width: imgSize.width * r, height: imgSize.height * r)
        case .fitWidth:
            let r = bounds.width / imgSize.width
            base = CGSize(width: bounds.width, height: imgSize.height * r)
        case .fitHeight:
            let r = bounds.height / imgSize.height
            base = CGSize(width: imgSize.width * r, height: bounds.height)
        case .original:
            // Pixels da imagem (já reduzida pelo pipeline) em pontos de tela.
            let s = image.scale / UIScreen.main.scale
            base = CGSize(width: imgSize.width * s, height: imgSize.height * s)
        }
        imageView.frame = CGRect(origin: .zero, size: base)
        contentSize = base
        minimumZoomScale = 1
        maximumZoomScale = 4
        // Ajuste à largura começa no topo; os demais, centralizados.
        contentOffset = CGPoint(x: max(0, (base.width - bounds.width) / 2), y: 0)
        alwaysBounceVertical = base.height > bounds.height
        alwaysBounceHorizontal = false
        centerContent()
    }

    /// Centraliza a imagem quando ela é menor que a área visível.
    func centerContent() {
        let size = imageView.frame.size
        let insetX = max(0, (bounds.width - size.width) / 2)
        let insetY = max(0, (bounds.height - size.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    /// Sem zoom e com a imagem cabendo na largura, deixa o gesto horizontal
    /// para o paginador do leitor.
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, zoomScale <= minimumZoomScale + 0.01, contentSize.width <= bounds.width + 1 {
            let v = panGestureRecognizer.velocity(in: self)
            if abs(v.x) > abs(v.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}
