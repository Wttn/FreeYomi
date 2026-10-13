import Foundation

/// Decodificador mínimo do formato binário Protocol Buffers (wire format).
///
/// Implementado à mão para evitar dependências: o índice Keiyoushi usa apenas
/// varints, strings e mensagens aninhadas. Campos desconhecidos são ignorados
/// (compatibilidade futura), tipos de fio inválidos geram erro.
public struct ProtobufReader {
    public enum WireType: UInt8 {
        case varint = 0
        case fixed64 = 1
        case lengthDelimited = 2
        case startGroup = 3
        case endGroup = 4
        case fixed32 = 5
    }

    public enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)

        public var uint64: UInt64? {
            switch self {
            case .varint(let v), .fixed64(let v): return v
            case .fixed32(let v): return UInt64(v)
            case .bytes: return nil
            }
        }

        public var int64: Int64? { uint64.map { Int64(bitPattern: $0) } }

        public var string: String? {
            if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }
            return nil
        }

        public var data: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }
    }

    public struct Field {
        public let number: UInt32
        public let value: Value
    }

    private let bytes: [UInt8]
    private var offset = 0
    /// Profundidade de aninhamento, para evitar recursão infinita em dados maliciosos.
    public let depth: Int
    public static let maxDepth = 32

    public init(data: Data, depth: Int = 0) throws {
        guard depth <= Self.maxDepth else { throw FYError.invalidData("protobuf aninhado demais") }
        self.bytes = [UInt8](data)
        self.depth = depth
    }

    public var isAtEnd: Bool { offset >= bytes.count }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count else { throw FYError.invalidData("varint truncado") }
            let byte = bytes[offset]
            offset += 1
            if shift == 63 && byte > 1 { throw FYError.invalidData("varint excede 64 bits") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw FYError.invalidData("varint longo demais") }
        }
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard offset + count <= bytes.count else { throw FYError.invalidData("campo fixo truncado") }
        var value: UInt64 = 0
        for i in 0..<count { value |= UInt64(bytes[offset + i]) << (8 * UInt64(i)) }
        offset += count
        return value
    }

    /// Lê o próximo campo, ou `nil` ao fim da mensagem.
    public mutating func nextField() throws -> Field? {
        guard !isAtEnd else { return nil }
        let key = try readVarint()
        let number = UInt32(truncatingIfNeeded: key >> 3)
        guard number > 0 else { throw FYError.invalidData("número de campo 0") }
        guard let wire = WireType(rawValue: UInt8(key & 0x7)) else {
            throw FYError.invalidData("tipo de fio desconhecido \(key & 0x7)")
        }
        switch wire {
        case .varint:
            return Field(number: number, value: .varint(try readVarint()))
        case .fixed64:
            return Field(number: number, value: .fixed64(try readFixed(8)))
        case .fixed32:
            return Field(number: number, value: .fixed32(UInt32(try readFixed(4))))
        case .lengthDelimited:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - offset) else {
                throw FYError.invalidData("campo delimitado excede a mensagem")
            }
            let end = offset + Int(length)
            let slice = Data(bytes[offset..<end])
            offset = end
            return Field(number: number, value: .bytes(slice))
        case .startGroup, .endGroup:
            throw FYError.invalidData("grupos protobuf não são suportados")
        }
    }

    /// Lê todos os campos restantes.
    public mutating func readAll() throws -> [Field] {
        var fields: [Field] = []
        while let f = try nextField() { fields.append(f) }
        return fields
    }
}

/// Codificador mínimo, usado nos testes para gerar fixtures determinísticas.
public struct ProtobufWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeVarint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    public mutating func varint(_ field: UInt32, _ value: UInt64) {
        writeVarint(UInt64(field) << 3 | 0)
        writeVarint(value)
    }

    public mutating func int64(_ field: UInt32, _ value: Int64) {
        varint(field, UInt64(bitPattern: value))
    }

    public mutating func bytes(_ field: UInt32, _ value: Data) {
        writeVarint(UInt64(field) << 3 | 2)
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: UInt32, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    public mutating func message(_ field: UInt32, _ build: (inout ProtobufWriter) -> Void) {
        var nested = ProtobufWriter()
        build(&nested)
        bytes(field, nested.data)
    }
}
