import XCTest
@testable import FYCore

final class GzipTests: XCTestCase {
    func testRoundTrip() throws {
        let original = Data((0..<50_000).map { UInt8($0 % 251) })
        let compressed = try Gzip.compress(original)
        XCTAssertTrue(Gzip.isGzip(compressed))
        XCTAssertEqual(try Gzip.decompress(compressed), original)
    }

    func testCorruptedDataThrows() {
        var bad = Data([0x1F, 0x8B, 0x08, 0x00])
        bad.append(Data(repeating: 0xFF, count: 40))
        XCTAssertThrowsError(try Gzip.decompress(bad))
    }

    func testOutputLimitProtectsAgainstBombs() throws {
        let zeros = Data(count: 2_000_000)
        let compressed = try Gzip.compress(zeros)
        XCTAssertThrowsError(try Gzip.decompress(compressed, maxOutput: 100_000))
    }
}

final class ProtobufTests: XCTestCase {
    func testVarintAndStrings() throws {
        var w = ProtobufWriter()
        w.string(1, "Olá")
        w.int64(2, -42)
        w.varint(3, 300)
        w.message(4) { $0.string(1, "aninhado") }
        var r = try ProtobufReader(data: w.data)
        let fields = try r.readAll()
        XCTAssertEqual(fields.count, 4)
        XCTAssertEqual(fields[0].value.string, "Olá")
        XCTAssertEqual(fields[1].value.int64, -42)
        XCTAssertEqual(fields[2].value.uint64, 300)
        var nested = try ProtobufReader(data: fields[3].value.data!)
        XCTAssertEqual(try nested.nextField()?.value.string, "aninhado")
    }

    func testLargeUInt64SourceId() throws {
        // IDs de fonte do Keiyoushi usam todo o intervalo de 64 bits.
        var w = ProtobufWriter()
        w.int64(1, 9_222_445_553_932_717_105)
        var r = try ProtobufReader(data: w.data)
        XCTAssertEqual(try r.nextField()?.value.int64, 9_222_445_553_932_717_105)
    }

    func testTruncatedLengthThrows() throws {
        var r = try ProtobufReader(data: Data([0x0A, 0x10, 0x41]))
        XCTAssertThrowsError(try r.nextField())
    }

    func testInvalidWireTypeThrows() throws {
        var r = try ProtobufReader(data: Data([0x0F]))
        XCTAssertThrowsError(try r.nextField())
    }
}

final class SecurityTests: XCTestCase {
    func testRedactsCredentials() {
        let url = URL(string: "https://user:secret@example.com/api?token=abc&page=2")!
        let redacted = Redactor.redact(url)
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertTrue(redacted.contains("page=2"))
    }

    func testOnlyHTTPSAllowed() {
        XCTAssertNoThrow(try URLPolicy.validateRemote(URL(string: "https://example.com")!))
        XCTAssertThrowsError(try URLPolicy.validateRemote(URL(string: "http://example.com")!))
        XCTAssertThrowsError(try URLPolicy.validateRemote(URL(string: "file:///etc/passwd")!))
    }

    func testZipSlipPathsRejected() {
        XCTAssertEqual(PathSanitizer.safeRelativePath("vol1/./001.jpg"), "vol1/001.jpg")
        XCTAssertNil(PathSanitizer.safeRelativePath("../../etc/passwd"))
        XCTAssertNil(PathSanitizer.safeRelativePath("/abs/path.png"))
        XCTAssertNil(PathSanitizer.safeRelativePath("a\\..\\..\\b.png"))
        XCTAssertNil(PathSanitizer.safeRelativePath("C:/windows/x.png"))
    }
}
