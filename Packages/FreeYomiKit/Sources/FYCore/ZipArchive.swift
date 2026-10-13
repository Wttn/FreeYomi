import Foundation

/// Leitor de arquivos ZIP (CBZ, ZIP e EPUB) escrito para entrada NÃO confiável.
///
/// Defesas:
/// - lê o diretório central a partir do fim do arquivo, com limites de
///   quantidade de entradas, tamanho por entrada, tamanho total e taxa de
///   compressão (proteção contra "zip bombs");
/// - descompressão exige exatamente o tamanho declarado e confere o CRC-32;
/// - entradas criptografadas, ZIP64, multi-volume e métodos diferentes de
///   "stored"/"deflate" são recusados com mensagem clara;
/// - nomes passam por `PathSanitizer` (proteção contra "zip slip"); o
///   chamador decide o caminho de destino, nunca o conteúdo do arquivo.
/// O arquivo é lido sob demanda (`FileHandle`), sem carregá-lo inteiro na memória.
public final class ZipArchive {
    public struct Limits: Sendable {
        public var maxEntries = 20_000
        public var maxEntrySize: Int = 256 * 1024 * 1024
        public var maxTotalSize: Int = 8 * 1024 * 1024 * 1024
        /// Taxa máxima descomprimido/comprimido para entradas acima de 1 MB.
        public var maxCompressionRatio = 250
        public init() {}
    }

    public struct Entry: Sendable, Hashable {
        /// Nome original (como gravado no arquivo).
        public let rawPath: String
        /// Caminho relativo seguro, ou `nil` se o nome for perigoso.
        public let safePath: String?
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { rawPath.hasSuffix("/") || rawPath.hasSuffix("\\") }
        public var isEncrypted: Bool { flags & 0x1 != 0 }
        /// Nome do arquivo sem diretórios.
        public var fileName: String {
            String((safePath ?? rawPath).split(separator: "/").last ?? "")
        }
    }

    public let url: URL
    public let entries: [Entry]
    public let limits: Limits
    private let handle: FileHandle
    private let fileSize: Int

    public init(url: URL, limits: Limits = Limits()) throws {
        self.url = url
        self.limits = limits
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FYError.notFound("não foi possível abrir \(url.lastPathComponent)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        fileSize = size
        do {
            entries = try Self.readCentralDirectory(handle: handle, fileSize: size, limits: limits)
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit { try? handle.close() }

    // MARK: Leitura

    private static func read(_ handle: FileHandle, at offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw FYError.invalidData("arquivo ZIP truncado") }
        return data
    }

    private static func readCentralDirectory(handle: FileHandle, fileSize: Int, limits: Limits) throws -> [Entry] {
        guard fileSize >= 22 else { throw FYError.invalidData("arquivo pequeno demais para ser um ZIP") }
        // O registro final (EOCD) fica nos últimos 22 bytes + comentário (até 65 535 bytes).
        let tailLength = min(fileSize, 22 + 0xFFFF)
        let tail = [UInt8](try read(handle, at: fileSize - tailLength, count: tailLength))
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { throw FYError.invalidData("não é um arquivo ZIP válido (registro final ausente)") }

        let disk = le16(tail, e + 4), cdDisk = le16(tail, e + 6)
        let total = Int(le16(tail, e + 10))
        let cdSize = Int(le32(tail, e + 12))
        let cdOffset = Int(le32(tail, e + 16))
        if disk != 0 || cdDisk != 0 { throw FYError.unsupported("ZIP dividido em vários volumes") }
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw FYError.unsupported("ZIP64 (arquivos acima de 4 GB) ainda não é suportado")
        }
        guard total <= limits.maxEntries else { throw FYError.invalidData("ZIP com entradas demais (\(total))") }
        guard cdOffset + cdSize <= fileSize else { throw FYError.invalidData("diretório central fora do arquivo") }

        let cd = [UInt8](try read(handle, at: cdOffset, count: cdSize))
        var entries: [Entry] = []
        entries.reserveCapacity(total)
        var p = 0
        var totalSize = 0
        for _ in 0..<total {
            guard p + 46 <= cd.count, le32(cd, p) == 0x0201_4B50 else {
                throw FYError.invalidData("diretório central corrompido")
            }
            let flags = le16(cd, p + 8)
            let method = le16(cd, p + 10)
            let crc = le32(cd, p + 16)
            let csize = Int(le32(cd, p + 20))
            let usize = Int(le32(cd, p + 24))
            let nameLen = Int(le16(cd, p + 28)), extraLen = Int(le16(cd, p + 30)), commentLen = Int(le16(cd, p + 32))
            let localOffset = Int(le32(cd, p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else {
                throw FYError.invalidData("nome de entrada fora dos limites")
            }
            let nameBytes = Data(cd[(p + 46)..<(p + 46 + nameLen)])
            let name = (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : nil)
                ?? String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            p += 46 + nameLen + extraLen + commentLen

            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw FYError.unsupported("ZIP64 (arquivos acima de 4 GB) ainda não é suportado")
            }
            guard usize <= limits.maxEntrySize else {
                throw FYError.invalidData("entrada \"\(name)\" grande demais (\(usize / 1_048_576) MB)")
            }
            if usize > 1_048_576 && csize > 0 && usize / max(csize, 1) > limits.maxCompressionRatio {
                throw FYError.invalidData("taxa de compressão suspeita em \"\(name)\"")
            }
            totalSize += usize
            guard totalSize <= limits.maxTotalSize else {
                throw FYError.invalidData("conteúdo descomprimido excede o limite")
            }
            guard localOffset < fileSize else { throw FYError.invalidData("entrada aponta para fora do arquivo") }
            entries.append(Entry(rawPath: name, safePath: PathSanitizer.safeRelativePath(name), method: method,
                                 flags: flags, crc32: crc, compressedSize: csize, uncompressedSize: usize,
                                 localHeaderOffset: localOffset))
        }
        return entries
    }

    /// Extrai o conteúdo de uma entrada, validando tamanho e CRC.
    public func data(for entry: Entry) throws -> Data {
        if entry.isEncrypted { throw FYError.unsupported("arquivos ZIP protegidos por senha") }
        let header = [UInt8](try Self.read(handle, at: entry.localHeaderOffset, count: 30))
        guard Self.le32(header, 0) == 0x0403_4B50 else { throw FYError.invalidData("cabeçalho local inválido") }
        let nameLen = Int(Self.le16(header, 26)), extraLen = Int(Self.le16(header, 28))
        let start = entry.localHeaderOffset + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= fileSize else { throw FYError.invalidData("entrada truncada") }
        let raw = try Self.read(handle, at: start, count: entry.compressedSize)

        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else {
                throw FYError.invalidData("entrada sem compressão com tamanhos divergentes")
            }
            output = raw
        case 8:
            output = try RawInflate.inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            throw FYError.unsupported("método de compressão \(entry.method) (use ZIP comum/deflate)")
        }
        guard CRC32.checksum(output) == entry.crc32 else {
            throw FYError.invalidData("CRC inválido em \"\(entry.fileName)\" (arquivo corrompido)")
        }
        return output
    }

    /// Busca uma entrada pelo caminho seguro (sem diferenciar maiúsculas).
    public func entry(path: String) -> Entry? {
        let wanted = PathSanitizer.safeRelativePath(path)?.lowercased()
        return entries.first { $0.safePath?.lowercased() == wanted }
    }

    // MARK: Bytes little-endian

    static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// Gravador de ZIP simples (stored/deflate). Usado em testes e para gerar a
/// amostra local dos testes de interface. Não é usado para dados do usuário.
public struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count = 0

    public init() {}

    public mutating func add(path: String, data: Data, compress: Bool = true) throws {
        let crc = CRC32.checksum(data)
        let payload = compress ? try RawInflate.deflate(data) : data
        let method: UInt16 = compress ? 8 : 0
        let name = Data(path.utf8)
        let offset = UInt32(body.count)

        var local = Data()
        local.le32(0x0403_4B50); local.le16(20); local.le16(0x800); local.le16(method)
        local.le16(0); local.le16(0x21) // hora/data fixas (1980-01-01)
        local.le32(crc); local.le32(UInt32(payload.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(name.count)); local.le16(0)
        body.append(local); body.append(name); body.append(payload)

        var c = Data()
        c.le32(0x0201_4B50); c.le16(20); c.le16(20); c.le16(0x800); c.le16(method)
        c.le16(0); c.le16(0x21)
        c.le32(crc); c.le32(UInt32(payload.count)); c.le32(UInt32(data.count))
        c.le16(UInt16(name.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0); c.le32(0)
        c.le32(offset)
        central.append(c); central.append(name)
        count += 1
    }

    public func finish() -> Data {
        var out = body
        out.append(central)
        var e = Data()
        e.le32(0x0605_4B50); e.le16(0); e.le16(0)
        e.le16(UInt16(count)); e.le16(UInt16(count))
        e.le32(UInt32(central.count)); e.le32(UInt32(body.count)); e.le16(0)
        out.append(e)
        return out
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
