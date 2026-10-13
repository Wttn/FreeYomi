import Foundation
import CZlib

/// Descompressão gzip/zlib baseada na zlib do sistema.
public enum Gzip {
    /// Limite padrão do tamanho descomprimido (proteção contra "zip bombs").
    public static let defaultMaxOutput = 64 * 1024 * 1024

    /// Indica se os dados começam com o cabeçalho mágico do gzip (1F 8B).
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Descomprime dados gzip ou zlib (detecção automática do cabeçalho).
    /// - Throws: `FYError.invalidData` se os dados estiverem corrompidos ou
    ///   se ultrapassarem `maxOutput` bytes.
    public static func decompress(_ data: Data, maxOutput: Int = defaultMaxOutput) throws -> Data {
        if data.isEmpty { return Data() }

        var stream = z_stream()
        // 15 + 32: janela máxima + detecção automática de gzip/zlib
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw FYError.invalidData("zlib não inicializou (\(status))") }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            guard let base = input.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)

            repeat {
                status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else {
                    throw FYError.invalidData("gzip corrompido (código \(status))")
                }
                let produced = chunkSize - Int(stream.avail_out)
                output.append(contentsOf: chunk[0..<produced])
                if output.count > maxOutput {
                    throw FYError.invalidData("conteúdo descomprimido excede \(maxOutput) bytes")
                }
                if status == Z_OK && stream.avail_in == 0 && produced == 0 {
                    throw FYError.invalidData("gzip truncado")
                }
            } while status != Z_STREAM_END
        }
        return output
    }

    /// Comprime dados no formato gzip. Usado em testes e, futuramente, em backups.
    public static func compress(_ data: Data, level: Int32 = Z_DEFAULT_COMPRESSION) throws -> Data {
        var stream = z_stream()
        // 15 + 16: janela máxima + cabeçalho gzip
        var status = deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw FYError.invalidData("deflate não inicializou (\(status))") }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var inputCopy = [UInt8](data)

        inputCopy.withUnsafeMutableBufferPointer { input in
            stream.next_in = input.baseAddress
            stream.avail_in = uInt(input.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                output.append(contentsOf: chunk[0..<(chunkSize - Int(stream.avail_out))])
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw FYError.invalidData("falha ao comprimir (\(status))") }
        return output
    }
}

/// DEFLATE "cru" (sem cabeçalho), usado pelas entradas de arquivos ZIP.
public enum RawInflate {
    /// Descomprime exatamente `expectedSize` bytes. Falha se o fluxo produzir
    /// mais ou menos dados do que o declarado (defesa contra cabeçalhos falsos).
    public static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var stream = z_stream()
        var status = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw FYError.invalidData("zlib não inicializou (\(status))") }
        defer { inflateEnd(&stream) }

        var output = Data(count: expectedSize + 1) // +1 detecta excesso
        var input = [UInt8](data)
        let produced: Int = try output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            guard let outBase = out.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return try input.withUnsafeMutableBufferPointer { inBuf -> Int in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBase
                stream.avail_out = uInt(expectedSize + 1)
                status = CZlib.inflate(&stream, Z_FINISH)
                guard status == Z_STREAM_END || status == Z_BUF_ERROR || status == Z_OK else {
                    throw FYError.invalidData("dados comprimidos corrompidos (código \(status))")
                }
                return expectedSize + 1 - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END, produced == expectedSize else {
            throw FYError.invalidData("tamanho descomprimido difere do declarado (\(produced) ≠ \(expectedSize))")
        }
        output.removeLast()
        return output
    }

    /// Comprime em DEFLATE cru (usado pelo `ZipWriter`).
    public static func deflate(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                                   ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw FYError.invalidData("deflate não inicializou (\(status))") }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(data.count))) + 16
        var output = Data(count: bound)
        var input = [UInt8](data)
        let written: Int = output.withUnsafeMutableBytes { out in
            input.withUnsafeMutableBufferPointer { inBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = out.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(bound)
                status = CZlib.deflate(&stream, Z_FINISH)
                return bound - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END else { throw FYError.invalidData("falha ao comprimir (\(status))") }
        output.count = written
        return output
    }
}

/// CRC-32 (IEEE), o mesmo do ZIP e do gzip.
public enum CRC32 {
    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf -> UInt32 in
            guard let base = buf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, base, uInt(buf.count)))
        }
    }
}
