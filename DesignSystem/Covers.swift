import SwiftUI
import FYDomain
import FYSources
import FYCore
import FYData
import FYServices

/// Capa de um título. Suporta capas remotas, capas de demonstração
/// (desenhadas localmente) e o placeholder de imagem indisponível
/// (como na captura do Histórico).
struct CoverView: View {
    let manga: Manga
    var cornerRadius: CGFloat = FYMetrics.coverCornerRadius

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let cover = manga.coverURL, cover.hasPrefix("freeyomi-demo://") {
            DemoCoverArt(title: manga.title, hue: DemoSource.hue(for: manga.key))
        } else if let cover = manga.coverURL, let rel = LocalSource.relativePath(fromCoverURL: cover) {
            CoverImage(ref: .file(relativePath: rel))
        } else if let cover = manga.coverURL, let url = URL(string: cover), url.scheme == "https" || url.scheme == "http" {
            // HTTP só é aceito pelo pipeline para o servidor de extensões configurado.
            // Fontes que exigem cabeçalhos (Referer etc.) os informam ao registrar-se.
            CoverImage(ref: .remote(url: cover, headers: SourceImageHeaders.shared.headers(for: manga.sourceId)))
        } else {
            CoverPlaceholder()
        }
    }
}

/// Capa carregada pelo pipeline (reduzida, com cache em memória e em disco).
struct CoverImage: View {
    let ref: ImageRef
    @State private var image: UIImage?
    @State private var failed = false

    init(ref: ImageRef) { self.ref = ref }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if failed {
                CoverPlaceholder()
            } else {
                FYColor.placeholder
            }
        }
        .task(id: ref) {
            do {
                image = try await ImagePipeline.shared.image(for: ref, targetPixelWidth: ImagePipeline.pixelWidth(forPoints: 220, zoomHeadroom: 1))
            } catch {
                failed = true
            }
        }
    }
}

struct CoverPlaceholder: View {
    var body: some View {
        ZStack {
            FYColor.placeholder
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}

/// Arte gerada para títulos de demonstração. Não usa imagens de terceiros.
struct DemoCoverArt: View {
    let title: String
    let hue: Int

    private var base: Color { Color(hue: Double(hue) / 360, saturation: 0.55, brightness: 0.55) }
    private var light: Color { Color(hue: Double(hue) / 360, saturation: 0.35, brightness: 0.85) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [light, base], startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { geo in
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: geo.size.width * 0.9)
                    .offset(x: geo.size.width * 0.35, y: geo.size.height * 0.1)
                Image(systemName: "book.pages")
                    .font(.system(size: geo.size.width * 0.28, weight: .light))
                    .foregroundStyle(.white.opacity(0.75))
                    .position(x: geo.size.width * 0.5, y: geo.size.height * 0.4)
            }
            Text("DEMO")
                .font(.caption2.weight(.heavy))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: Capsule())
                .foregroundStyle(.white)
                .padding(8)
        }
    }
}

/// Página desenhada localmente para a fonte de demonstração.
struct DemoPageView: View {
    let seed: Int
    let label: String
    let aspectRatio: Double

    var body: some View {
        let hue = Double(seed % 360) / 360
        ZStack {
            Color(white: 0.96)
            VStack(spacing: 10) {
                ForEach(0..<panelRows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<(row % 2 == 0 ? 2 : 1), id: \.self) { col in
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.black, lineWidth: 3)
                                .background(
                                    Color(hue: hue, saturation: 0.18 + 0.1 * Double((row + col) % 3), brightness: 0.95)
                                )
                        }
                    }
                }
            }
            .padding(18)
            Text(label)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white, in: Capsule())
                .overlay(Capsule().stroke(.black, lineWidth: 2))
                .foregroundStyle(.black)
        }
        .aspectRatio(1 / aspectRatio, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Página de demonstração: \(label)")
    }

    private var panelRows: Int { aspectRatio > 2 ? 7 : 3 }
}

struct PageErrorView: View {
    let index: Int
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
            Text("Não foi possível carregar a página \(index + 1).")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// Emblema de capítulos não lidos (pílula clara, canto superior esquerdo da capa).
struct UnreadBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(FYColor.badgeBackground, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(FYColor.badgeForeground)
            .accessibilityLabel("\(count) capítulos não lidos")
    }
}

/// Estado vazio padrão.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}
