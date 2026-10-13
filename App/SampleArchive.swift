import UIKit
import FYCore

/// Gera um CBZ de amostra com páginas desenhadas pelo app, usado apenas nos
/// testes de interface (`-ui-testing-sample`) para exercitar importação,
/// zoom, rolagem e memória sem depender de conteúdo de terceiros.
enum SampleArchive {
    static func make() throws -> URL {
        var writer = ZipWriter()
        let sizes: [CGSize] = [
            CGSize(width: 1400, height: 2000), CGSize(width: 1400, height: 2000), CGSize(width: 2800, height: 2000),
            CGSize(width: 1400, height: 2000), CGSize(width: 900, height: 9000), CGSize(width: 1400, height: 2000),
        ]
        for (i, size) in sizes.enumerated() {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor(hue: CGFloat(i) / CGFloat(sizes.count), saturation: 0.25, brightness: 0.95, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                UIColor.black.setStroke()
                ctx.cgContext.setLineWidth(12)
                ctx.cgContext.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 40, dy: 40))
                let text = "Amostra · página \(i + 1)" as NSString
                text.draw(at: CGPoint(x: 80, y: 80),
                          withAttributes: [.font: UIFont.boldSystemFont(ofSize: 90), .foregroundColor: UIColor.black])
            }
            guard let data = image.jpegData(compressionQuality: 0.7) else { continue }
            try writer.add(path: String(format: "pagina-%02d.jpg", i + 1), data: data, compress: false)
        }
        let info = """
        <?xml version="1.0"?><ComicInfo><Series>Amostra local</Series><Number>1</Number>\
        <Writer>FreeYomi (gerado)</Writer><Summary>Arquivo gerado para testes.</Summary></ComicInfo>
        """
        try writer.add(path: "ComicInfo.xml", data: Data(info.utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amostra-local.cbz")
        try writer.finish().write(to: url, options: .atomic)
        return url
    }
}
