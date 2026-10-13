import Foundation
import FYCore
import FYDomain
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Manifesto

/// Descrição de um título importado, salva em `<raiz>/<id>/manifest.json`.
public struct LocalManifest: Codable, Sendable, Hashable, Identifiable {
    public var version = 1
    public var id: String
    public var title: String
    public var author: String?
    public var summary: String?
    /// Nome do arquivo ou pasta original (apenas informativo).
    public var originalName: String
    /// Impressão digital do original (nome + tamanho + quantidade de páginas), para evitar duplicatas.
    public var fingerprint: String
    public var importedAt: Date
    public var chapters: [LocalChapter]

    public var pageCount: Int { chapters.reduce(0) { $0 + $1.pages.count } }
    /// Primeira página do primeiro capítulo, usada como capa.
    public var coverPath: String? { chapters.first?.pages.first.map { "\(id)/\($0)" } }
}

public struct LocalChapter: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    public var number: Double
    /// Caminhos relativos à pasta do título.
    public var pages: [String]
}

/// Pasta de títulos importados (dentro do contêiner do app).
public final class LocalLibraryStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func all() -> [LocalManifest] {
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { manifest(id: $0.lastPathComponent) }
            .sorted { NaturalOrder.less($0.title, $1.title) }
    }

    public func manifest(id: String) -> LocalManifest? {
        guard PathSanitizer.safeRelativePath(id) == id else { return nil }
        let url = root.appendingPathComponent(id).appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LocalManifest.self, from: data)
    }

    func save(_ m: LocalManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(m).write(to: root.appendingPathComponent(m.id).appendingPathComponent("manifest.json"),
                                    options: .atomic)
    }

    /// Remove os arquivos de um título importado.
    public func delete(id: String) throws {
        guard PathSanitizer.safeRelativePath(id) == id, !id.contains("/") else {
            throw FYError.invalidData("identificador inválido")
        }
        let dir = root.appendingPathComponent(id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    /// Caminho absoluto de um arquivo relativo à raiz, recusando caminhos inseguros.
    public func fileURL(relativePath: String) -> URL? {
        guard let safe = PathSanitizer.safeRelativePath(relativePath) else { return nil }
        return root.appendingPathComponent(safe)
    }

    /// Espaço ocupado em bytes.
    public func diskUsage() -> Int {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }
}

// MARK: - Importador

public struct ImportResult: Sendable {
    public var manifest: LocalManifest
    /// `true` quando o mesmo arquivo já tinha sido importado.
    public var wasDuplicate: Bool
    /// Itens ignorados (arquivos que não são imagem, nomes inseguros, imagens corrompidas…).
    public var skipped: [String]
}

/// Importa CBZ/ZIP, EPUB (de imagens) e pastas de imagens para a biblioteca local.
///
/// As páginas são renumeradas (`0001.jpg`, `0002.png`…) dentro de uma pasta
/// criada pelo app: nenhum nome vindo do arquivo é usado como caminho de destino.
public final class LocalImporter: @unchecked Sendable {
    public struct Limits: Sendable {
        public var maxPagesPerChapter = 3_000
        public var maxChapters = 2_000
        public var maxImageBytes = 64 * 1024 * 1024
        public var zip = ZipArchive.Limits()
        public init() {}
    }

    public let store: LocalLibraryStore
    public let limits: Limits
    private let fm = FileManager.default

    public init(store: LocalLibraryStore, limits: Limits = Limits()) {
        self.store = store
        self.limits = limits
    }

    public static let archiveExtensions: Set<String> = ["cbz", "zip"]
    public static let epubExtensions: Set<String> = ["epub"]

    /// Importa um arquivo ou pasta. Em caso de erro, nada fica gravado.
    public func importItem(at url: URL) throws -> ImportResult {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FYError.notFound(url.lastPathComponent)
        }
        let ext = url.pathExtension.lowercased()
        if !isDir.boolValue && !Self.archiveExtensions.contains(ext) && !Self.epubExtensions.contains(ext) {
            if ext == "cbr" || ext == "rar" || ext == "cb7" || ext == "7z" {
                throw FYError.unsupported("arquivos .\(ext) (RAR/7z). Converta para CBZ")
            }
            throw FYError.unsupported("o formato .\(ext)")
        }

        let id = UUID().uuidString
        let dir = store.root.appendingPathComponent(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var writer = PageWriter(mangaDir: dir, limits: limits)

        do {
            var meta = Metadata(title: url.deletingPathExtension().lastPathComponent)
            if isDir.boolValue {
                try importFolder(url, into: &writer, meta: &meta)
            } else if Self.epubExtensions.contains(ext) {
                try importEPUB(url, into: &writer, meta: &meta)
            } else {
                try importArchive(url, chapterName: nil, into: &writer, meta: &meta, allowGrouping: true)
            }
            let chapters = writer.chapters.filter { !$0.pages.isEmpty }
            guard !chapters.isEmpty else {
                throw FYError.invalidData("nenhuma imagem válida encontrada em \"\(url.lastPathComponent)\"")
            }
            let fingerprint = Self.fingerprint(url: url, isDirectory: isDir.boolValue, pages: writer.totalPages)
            if let existing = store.all().first(where: { $0.fingerprint == fingerprint }) {
                try? fm.removeItem(at: dir)
                return ImportResult(manifest: existing, wasDuplicate: true, skipped: writer.skipped)
            }
            let manifest = LocalManifest(id: id, title: meta.title, author: meta.author, summary: meta.summary,
                                         originalName: url.lastPathComponent, fingerprint: fingerprint,
                                         importedAt: Date(), chapters: chapters)
            try store.save(manifest)
            return ImportResult(manifest: manifest, wasDuplicate: false, skipped: writer.skipped)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    static func fingerprint(url: URL, isDirectory: Bool, pages: Int) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return "\(url.lastPathComponent.lowercased())|\(isDirectory ? "dir" : String(size))|\(pages)"
    }

    struct Metadata {
        var title: String
        var author: String?
        var summary: String?
    }

    // MARK: CBZ / ZIP

    /// Um arquivo vira um capítulo; se as imagens estiverem em várias pastas
    /// (ex.: um volume com pastas de capítulos), cada pasta vira um capítulo.
    private func importArchive(_ url: URL, chapterName: String?, into writer: inout PageWriter,
                               meta: inout Metadata, allowGrouping: Bool) throws {
        let zip = try ZipArchive(url: url, limits: limits.zip)
        var info: ComicInfo?
        if let ci = zip.entries.first(where: { $0.fileName.lowercased() == "comicinfo.xml" }),
           let data = try? zip.data(for: ci) {
            info = ComicInfo.parse(data)
        }
        if chapterName == nil, let info {
            if let series = info.series, !series.isEmpty { meta.title = series }
            meta.author = info.writer ?? meta.author
            meta.summary = info.summary ?? meta.summary
        }

        var images: [ZipArchive.Entry] = []
        for e in zip.entries where !e.isDirectory {
            guard let safe = e.safePath else { writer.skipped.append("\(e.rawPath) (caminho inseguro)"); continue }
            if ImageFormat.looksLikeImageName(safe) { images.append(e) }
            else if !safe.lowercased().hasSuffix("comicinfo.xml") && !safe.hasPrefix("__MACOSX") {
                writer.skipped.append(safe)
            }
        }
        images.sort { NaturalOrder.less($0.safePath!, $1.safePath!) }

        let groups = Dictionary(grouping: images) { e -> String in
            let parts = e.safePath!.split(separator: "/")
            return parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
        }
        let baseName = chapterName ?? info?.title ?? url.deletingPathExtension().lastPathComponent
        if allowGrouping && groups.count > 1 {
            for key in groups.keys.sorted(by: NaturalOrder.less) {
                let name = key.split(separator: "/").last.map(String.init) ?? key
                try writer.beginChapter(name: name, number: NaturalOrder.firstNumber(in: name))
                for e in groups[key]! { try writer.addPage(try zip.data(for: e), label: e.safePath!) }
            }
        } else {
            let number = info?.number.flatMap(Double.init) ?? NaturalOrder.firstNumber(in: baseName)
            let name = chapterName ?? (info?.number.map { "Capítulo \($0)" } ?? baseName)
            try writer.beginChapter(name: name, number: number)
            for e in images { try writer.addPage(try zip.data(for: e), label: e.safePath!) }
        }
    }

    // MARK: Pastas

    /// Pasta com imagens → um capítulo. Pasta com subpastas/arquivos → um
    /// capítulo por subpasta ou por CBZ/ZIP (ordem natural).
    private func importFolder(_ url: URL, into writer: inout PageWriter, meta: inout Metadata) throws {
        meta.title = url.lastPathComponent
        let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])
            .sorted { NaturalOrder.less($0.lastPathComponent, $1.lastPathComponent) }
        let images = items.filter { ImageFormat.looksLikeImageName($0.lastPathComponent) }
        if !images.isEmpty {
            try writer.beginChapter(name: url.lastPathComponent, number: NaturalOrder.firstNumber(in: url.lastPathComponent))
            for f in images { try writer.addPage(try readFile(f), label: f.lastPathComponent) }
        }
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let name = item.deletingPathExtension().lastPathComponent
            if isDir {
                let files = ((try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? [])
                    .filter { ImageFormat.looksLikeImageName($0.lastPathComponent) }
                    .sorted { NaturalOrder.less($0.lastPathComponent, $1.lastPathComponent) }
                guard !files.isEmpty else { continue }
                try writer.beginChapter(name: name, number: NaturalOrder.firstNumber(in: name))
                for f in files { try writer.addPage(try readFile(f), label: f.lastPathComponent) }
            } else if Self.archiveExtensions.contains(item.pathExtension.lowercased()) {
                var ignored = meta
                try importArchive(item, chapterName: name, into: &writer, meta: &ignored, allowGrouping: false)
            } else if !ImageFormat.looksLikeImageName(item.lastPathComponent) {
                writer.skipped.append(item.lastPathComponent)
            }
        }
    }

    private func readFile(_ url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= limits.maxImageBytes else {
            throw FYError.invalidData("imagem grande demais: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }

    // MARK: EPUB (apenas EPUBs de imagens, como mangás e quadrinhos)

    private func importEPUB(_ url: URL, into writer: inout PageWriter, meta: inout Metadata) throws {
        let zip = try ZipArchive(url: url, limits: limits.zip)
        guard let containerEntry = zip.entry(path: "META-INF/container.xml"),
              let opfPath = EPUBParser.rootFile(fromContainer: try zip.data(for: containerEntry)),
              let opfEntry = zip.entry(path: opfPath) else {
            throw FYError.invalidData("EPUB sem META-INF/container.xml válido")
        }
        let opf = try EPUBParser.parseOPF(try zip.data(for: opfEntry))
        if let t = opf.title, !t.isEmpty { meta.title = t }
        meta.author = opf.creator
        meta.summary = opf.description

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var ordered: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            guard let safe = PathSanitizer.safeRelativePath(path), !seen.contains(safe.lowercased()) else { return }
            seen.insert(safe.lowercased())
            ordered.append(safe)
        }
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let docPath = EPUBParser.resolve(item.href, relativeTo: opfDir)
            if item.mediaType.hasPrefix("image/") { add(docPath); continue }
            guard let docEntry = zip.entry(path: docPath), let doc = try? zip.data(for: docEntry) else { continue }
            let docDir = (docPath as NSString).deletingLastPathComponent
            for src in EPUBParser.imageReferences(inXHTML: doc) {
                add(EPUBParser.resolve(src, relativeTo: docDir))
            }
        }
        guard !ordered.isEmpty else {
            throw FYError.unsupported("EPUB de texto (somente EPUBs compostos por imagens são suportados)")
        }
        try writer.beginChapter(name: meta.title, number: NaturalOrder.firstNumber(in: meta.title))
        for path in ordered {
            guard let e = zip.entry(path: path) else { writer.skipped.append("\(path) (ausente)"); continue }
            try writer.addPage(try zip.data(for: e), label: path)
        }
    }
}

/// Grava páginas renumeradas, validando o conteúdo de cada imagem.
struct PageWriter {
    let mangaDir: URL
    let limits: LocalImporter.Limits
    var chapters: [LocalChapter] = []
    var skipped: [String] = []
    var totalPages = 0

    init(mangaDir: URL, limits: LocalImporter.Limits) {
        self.mangaDir = mangaDir
        self.limits = limits
    }

    mutating func beginChapter(name: String, number: Double?) throws {
        guard chapters.count < limits.maxChapters else { throw FYError.invalidData("capítulos demais") }
        let key = String(format: "c%04d", chapters.count + 1)
        try FileManager.default.createDirectory(at: mangaDir.appendingPathComponent(key),
                                                withIntermediateDirectories: true)
        chapters.append(LocalChapter(key: key, name: name, number: number ?? Double(chapters.count + 1), pages: []))
    }

    mutating func addPage(_ data: Data, label: String) throws {
        guard var chapter = chapters.popLast() else { return }
        defer { chapters.append(chapter) }
        guard data.count <= limits.maxImageBytes else { skipped.append("\(label) (grande demais)"); return }
        guard let format = ImageFormat.detect(data) else { skipped.append("\(label) (não é imagem)"); return }
        guard chapter.pages.count < limits.maxPagesPerChapter else {
            throw FYError.invalidData("páginas demais em um capítulo")
        }
        let file = "\(chapter.key)/" + String(format: "%04d", chapter.pages.count + 1) + "." + format.fileExtension
        try data.write(to: mangaDir.appendingPathComponent(file), options: .atomic)
        chapter.pages.append(file)
        totalPages += 1
    }
}

// MARK: - ComicInfo.xml

/// Subconjunto do ComicInfo.xml (padrão de metadados de CBZ).
public struct ComicInfo: Sendable, Equatable {
    public var series: String?
    public var title: String?
    public var number: String?
    public var writer: String?
    public var summary: String?

    public static func parse(_ data: Data) -> ComicInfo? {
        let delegate = FlatXMLCollector(wanted: ["Series", "Title", "Number", "Writer", "Summary"])
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let v = delegate.values
        func clean(_ k: String) -> String? {
            guard let s = v[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return s
        }
        return ComicInfo(series: clean("Series"), title: clean("Title"), number: clean("Number"),
                         writer: clean("Writer"), summary: clean("Summary"))
    }
}

/// Coleta o texto da primeira ocorrência de cada elemento desejado.
final class FlatXMLCollector: NSObject, XMLParserDelegate {
    let wanted: Set<String>
    var values: [String: String] = [:]
    var attributes: [String: [[String: String]]] = [:]
    private var current: String?
    private var buffer = ""

    init(wanted: Set<String>) { self.wanted = wanted }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        attributes[local, default: []].append(attributeDict)
        if wanted.contains(local) && values[local] == nil {
            current = local
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == current {
            values[local] = buffer
            current = nil
        }
    }
}

// MARK: - EPUB

enum EPUBParser {
    struct ManifestItem { let href: String; let mediaType: String }
    struct OPF {
        var title: String?
        var creator: String?
        var description: String?
        var manifest: [String: ManifestItem] = [:]
        var spine: [String] = []
    }

    static func rootFile(fromContainer data: Data) -> String? {
        let c = FlatXMLCollector(wanted: [])
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.delegate = c
        guard p.parse() else { return nil }
        return c.attributes["rootfile"]?.first?["full-path"]
    }

    static func parseOPF(_ data: Data) throws -> OPF {
        let c = FlatXMLCollector(wanted: ["title", "creator", "description"])
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.delegate = c
        guard p.parse() else { throw FYError.invalidData("arquivo OPF do EPUB inválido") }
        var opf = OPF()
        opf.title = c.values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        opf.creator = c.values["creator"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        opf.description = c.values["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        for item in c.attributes["item"] ?? [] {
            if let id = item["id"], let href = item["href"] {
                opf.manifest[id] = ManifestItem(href: href.removingPercentEncoding ?? href,
                                                mediaType: item["media-type"] ?? "")
            }
        }
        opf.spine = (c.attributes["itemref"] ?? []).compactMap { $0["idref"] }
        return opf
    }

    /// Referências de imagem em um documento XHTML (`<img src>` e `<image xlink:href>`),
    /// extraídas por expressão regular para tolerar HTML malformado.
    static func imageReferences(inXHTML data: Data) -> [String] {
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        let pattern = #"<(?:img|image)\b[^>]*?\s(?:src|xlink:href|href)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            let raw = ns.substring(with: m.range(at: 1))
            if raw.hasPrefix("data:") || raw.contains("://") { return nil }
            return raw.removingPercentEncoding ?? raw
        }
    }

    /// Resolve `href` relativo a `base`, normalizando `./` e `../`.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let clean = href.split(separator: "#").first.map(String.init) ?? href
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for comp in clean.split(separator: "/") {
            if comp == "." { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(comp))
        }
        return parts.joined(separator: "/")
    }
}
