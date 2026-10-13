import Foundation

/// Ordenação "natural": "pag2" < "pag10", sem diferenciar maiúsculas.
/// Implementação própria para ter o mesmo resultado em iOS e Linux.
public enum NaturalOrder {
    public static func less(_ a: String, _ b: String) -> Bool {
        compare(a, b) == .orderedAscending
    }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = Array(a.lowercased().unicodeScalars), y = Array(b.lowercased().unicodeScalars)
        var i = 0, j = 0
        while i < x.count && j < y.count {
            let cx = x[i], cy = y[j]
            if isDigit(cx) && isDigit(cy) {
                var ei = i; while ei < x.count && isDigit(x[ei]) { ei += 1 }
                var ej = j; while ej < y.count && isDigit(y[ej]) { ej += 1 }
                let nx = String(String.UnicodeScalarView(x[i..<ei])).drop { $0 == "0" }
                let ny = String(String.UnicodeScalarView(y[j..<ej])).drop { $0 == "0" }
                if nx.count != ny.count { return nx.count < ny.count ? .orderedAscending : .orderedDescending }
                if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending }
                i = ei; j = ej
            } else {
                if cx != cy { return cx.value < cy.value ? .orderedAscending : .orderedDescending }
                i += 1; j += 1
            }
        }
        if x.count - i == y.count - j { return a < b ? .orderedAscending : (a == b ? .orderedSame : .orderedDescending) }
        return (x.count - i) < (y.count - j) ? .orderedAscending : .orderedDescending
    }

    private static func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 48 && s.value <= 57 }

    /// Primeiro número presente no texto ("Cap. 012.5 - X" → 12.5).
    public static func firstNumber(in text: String) -> Double? {
        var digits = ""
        var seenDot = false
        for ch in text {
            if ch.isASCII && ch.isNumber {
                digits.append(ch)
            } else if (ch == "." || ch == ",") && !digits.isEmpty && !seenDot {
                seenDot = true
                digits.append(".")
            } else if !digits.isEmpty {
                break
            }
        }
        if digits.hasSuffix(".") { digits.removeLast() }
        return Double(digits)
    }
}

/// Identificação de imagens pelo conteúdo (não pela extensão).
public enum ImageFormat: String, Sendable {
    case jpeg, png, gif, webp, heic, avif, bmp

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        default: return rawValue
        }
    }

    public static let candidateExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "jfif"]

    public static func detect(_ data: Data) -> ImageFormat? {
        let b = [UInt8](data.prefix(16))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF { return .jpeg }
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return .png }
        if b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38 { return .gif }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46
            && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50 { return .webp }
        if b[0] == 0x42 && b[1] == 0x4D { return .bmp }
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { // "ftyp"
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("avi") { return .avif }
            if ["heic", "heix", "mif1", "msf1", "hevc", "heim", "heis"].contains(brand) { return .heic }
        }
        return nil
    }

    /// Indica se o nome parece uma imagem e não é lixo de sistema (`__MACOSX`, `._x`, `.DS_Store`).
    public static func looksLikeImageName(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { return false }
        guard let name = parts.last else { return false }
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return candidateExtensions.contains(ext)
    }
}

/// Cache em disco com limite de tamanho e remoção dos itens menos usados.
/// Usado pelo pipeline de imagens para páginas e capas remotas.
public final class DiskCache: @unchecked Sendable {
    public let directory: URL
    public let maxBytes: Int
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(directory: URL, maxBytes: Int = 300 * 1024 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Nome de arquivo estável (FNV-1a de 64 bits) — independe de CryptoKit.
    public static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash) + ".bin"
    }

    private func url(for key: String) -> URL { directory.appendingPathComponent(Self.fileName(for: key)) }

    public func data(for key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let u = url(for: key)
        guard let d = try? Data(contentsOf: u) else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
        return d
    }

    public func store(_ data: Data, for key: String) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: url(for: key))
    }

    /// Tamanho atual em bytes.
    public var totalBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return entries().reduce(0) { $0 + $1.size }
    }

    private func entries() -> [(url: URL, size: Int, date: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.compactMap { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (u, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
        }
    }

    /// Remove os arquivos mais antigos até ficar abaixo de `maxBytes`.
    @discardableResult
    public func trim() -> Int {
        lock.lock(); defer { lock.unlock() }
        var all = entries().sorted { $0.date < $1.date }
        var total = all.reduce(0) { $0 + $1.size }
        var removed = 0
        while total > maxBytes, !all.isEmpty {
            let e = all.removeFirst()
            try? fm.removeItem(at: e.url)
            total -= e.size
            removed += 1
        }
        return removed
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
