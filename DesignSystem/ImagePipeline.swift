import SwiftUI
import UIKit
import ImageIO
import FYCore
import FYDomain
import FYSources

/// Pipeline de imagens do leitor e das capas.
///
/// - Decodifica com ImageIO já reduzido à resolução da tela
///   (`CGImageSourceCreateThumbnailAtIndex`), em vez de abrir a imagem
///   inteira: uma página de 4000×6000 px ocupa ~96 MB decodificada, mas só
///   ~10 MB na largura de um iPhone.
/// - Faixas longas de webtoon são reduzidas pela LARGURA, não pelo maior lado.
/// - Cache em memória (`NSCache`, limitado por bytes e esvaziado em alerta de
///   memória) + cache em disco para imagens remotas.
/// - Requisições iguais em andamento são compartilhadas; pré-carregamento e
///   cancelamento ao sair do capítulo.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var aspectCache: [String: CGFloat] = [:]
    private let http = URLSessionHTTPClient()
    let disk: DiskCache
    /// Raiz dos arquivos importados (para `ImageRef.file` e capas `freeyomi-local://`).
    var localRoot: URL?
    private var memoryObserver: NSObjectProtocol?

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        disk = DiskCache(directory: caches.appendingPathComponent("images", isDirectory: true))
        memory.totalCostLimit = 160 * 1024 * 1024
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.memory.removeAllObjects() }
        }
    }

    /// Largura alvo em pixels para uma largura em pontos (2× para permitir zoom com nitidez).
    static func pixelWidth(forPoints points: CGFloat, zoomHeadroom: CGFloat = 2) -> Int {
        let scale = UIScreen.main.scale
        return Int(min(points * scale * zoomHeadroom, 4096))
    }

    private func key(_ ref: ImageRef, _ width: Int) -> String {
        switch ref {
        case .remote(let url, _): return "r|\(url)|\(width)"
        case .file(let path): return "f|\(path)|\(width)"
        case .demo(let seed, _, _): return "d|\(seed)|\(width)"
        }
    }

    /// Carrega (ou reaproveita) a imagem reduzida para `targetPixelWidth`.
    func image(for ref: ImageRef, targetPixelWidth: Int) async throws -> UIImage {
        let k = key(ref, targetPixelWidth)
        if let cached = memory.object(forKey: k as NSString) { return cached }
        if let running = inFlight[k] { return try await running.value }

        let localRoot = self.localRoot
        let http = self.http
        let disk = self.disk
        let task = Task<UIImage, Error>.detached(priority: .userInitiated) {
            let data: Data
            switch ref {
            case .demo:
                throw FYError.unsupported("páginas de demonstração são desenhadas pela interface")
            case .file(let relative):
                guard let root = localRoot, let safe = PathSanitizer.safeRelativePath(relative) else {
                    throw FYError.notFound(relative)
                }
                let url = root.appendingPathComponent(safe)
                guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    throw FYError.notFound("arquivo da página")
                }
                data = d
            case .remote(let urlString, let headers):
                guard let url = URL(string: urlString) else { throw FYError.invalidData("URL de imagem inválida") }
                if let cached = disk.data(for: urlString) {
                    data = cached
                } else {
                    let response = try await http.get(url, headers: headers)
                    guard (200..<300).contains(response.statusCode) else {
                        throw FYError.httpStatus(response.statusCode, url: Redactor.redact(url))
                    }
                    guard ImageFormat.detect(response.body) != nil else {
                        throw FYError.invalidData("o servidor não retornou uma imagem")
                    }
                    disk.store(response.body, for: urlString)
                    data = response.body
                }
            }
            try Task.checkCancellation()
            return try Self.decode(data, targetPixelWidth: targetPixelWidth)
        }
        inFlight[k] = task
        defer { inFlight[k] = nil }
        let image = try await task.value
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: k as NSString, cost: cost)
        if aspectCache[aspectKey(ref)] == nil {
            aspectCache[aspectKey(ref)] = image.size.height / max(image.size.width, 1)
        }
        return image
    }

    /// Decodificação reduzida com ImageIO, sem decodificar a imagem inteira.
    nonisolated static func decode(_ data: Data, targetPixelWidth: Int) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw FYError.invalidData("imagem corrompida ou em formato não suportado")
        }
        var maxPixel = targetPixelWidth
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            // Reduz pela largura; o "maior lado" proporcional é o que o ImageIO espera.
            let scale = min(1, Double(targetPixelWidth) / Double(w))
            var longest = Double(max(w, h)) * scale
            // Teto de ~48 MP decodificados por imagem (faixas de webtoon muito longas).
            let pixels = Double(w) * scale * Double(h) * scale
            if pixels > 48_000_000 { longest *= (48_000_000 / pixels).squareRoot() }
            maxPixel = max(1, Int(longest))
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw FYError.invalidData("não foi possível decodificar a imagem")
        }
        return UIImage(cgImage: cg)
    }

    // MARK: Proporções (layout estável no modo vertical)

    private func aspectKey(_ ref: ImageRef) -> String { key(ref, 0) }

    func knownAspect(_ ref: ImageRef) -> CGFloat? {
        if case .demo(_, _, let ratio) = ref { return CGFloat(ratio) }
        return aspectCache[aspectKey(ref)]
    }

    /// Lê só o cabeçalho dos arquivos locais para obter largura/altura de cada
    /// página antes de exibi-las (sem decodificar pixels).
    func preloadAspects(_ pages: [Page]) async {
        let root = localRoot
        let refs = pages.map(\.image).filter { if case .file = $0 { return knownAspect($0) == nil }; return false }
        guard let root, !refs.isEmpty else { return }
        let results: [(String, CGFloat)] = await Task.detached(priority: .utility) {
            refs.compactMap { ref -> (String, CGFloat)? in
                guard case .file(let rel) = ref, let safe = PathSanitizer.safeRelativePath(rel),
                      let src = CGImageSourceCreateWithURL(root.appendingPathComponent(safe) as CFURL, nil),
                      let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
                      w > 0 else { return nil }
                return ("f|\(rel)|0", CGFloat(h) / CGFloat(w))
            }
        }.value
        for (k, v) in results { aspectCache[k] = v }
    }

    // MARK: Pré-carregamento

    func prefetch(_ refs: [ImageRef], targetPixelWidth: Int) {
        for ref in refs {
            if case .demo = ref { continue }
            let k = key(ref, targetPixelWidth)
            guard memory.object(forKey: k as NSString) == nil, prefetchTasks[k] == nil else { continue }
            prefetchTasks[k] = Task { [weak self] in
                _ = try? await self?.image(for: ref, targetPixelWidth: targetPixelWidth)
                self?.prefetchTasks[k] = nil
            }
        }
    }

    /// Cancela o pré-carregamento (ao sair do capítulo).
    func cancelPrefetch() {
        prefetchTasks.values.forEach { $0.cancel() }
        prefetchTasks.removeAll()
    }

    func clearMemory() { memory.removeAllObjects() }
}

/// Imagem carregada pelo pipeline, com estados de carregamento e erro.
struct PipelineImage: View {
    let ref: ImageRef
    var targetPointWidth: CGFloat = 400
    var contentMode: ContentMode = .fit
    var placeholderAspect: CGFloat? = nil
    var errorIndex: Int? = nil

    @State private var image: UIImage?
    @State private var failed: String?
    @State private var attempt = 0

    init(ref: ImageRef, targetPointWidth: CGFloat = 400, contentMode: ContentMode = .fit,
         placeholderAspect: CGFloat? = nil, errorIndex: Int? = nil) {
        self.ref = ref
        self.targetPointWidth = targetPointWidth
        self.contentMode = contentMode
        self.placeholderAspect = placeholderAspect
        self.errorIndex = errorIndex
    }

    var body: some View {
        // Com proporção conhecida, o contêiner tem a MESMA altura antes e
        // depois do carregamento: o layout do modo vertical nunca "salta"
        // (alturas variando ao carregar/descarregar podiam gerar um ciclo de
        // aparecer/desaparecer na borda da área visível e travar a rolagem).
        Group {
            if let aspect = placeholderAspect {
                Color.clear
                    .aspectRatio(1 / aspect, contentMode: .fit)
                    .overlay { content }
                    .clipped()
            } else {
                content
            }
        }
        .task(id: "\(attempt)|\(ref.hashValue)|\(Int(targetPointWidth))") {
            do {
                image = try await ImagePipeline.shared.image(
                    for: ref, targetPixelWidth: ImagePipeline.pixelWidth(forPoints: targetPointWidth))
            } catch {
                if !Task.isCancelled { failed = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
        } else if let failed {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title)
                Text(errorIndex.map { "Página \($0 + 1) indisponível" } ?? "Imagem indisponível").font(.callout)
                Text(failed).font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Tentar novamente") { self.failed = nil; attempt += 1 }.fySecondaryButton()
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: placeholderAspect == nil ? 240 : nil)
        } else {
            // Sem animação infinita: um indicador girando impede o "app ocioso"
            // dos testes e gasta energia em páginas fora de foco.
            ZStack {
                Color.gray.opacity(0.12)
                Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: placeholderAspect == nil ? 240 : nil)
            .accessibilityLabel("Carregando página")
        }
    }
}
