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

final class SHA256Tests: XCTestCase {
    /// Vetores oficiais (FIPS 180-4 / NIST).
    func testKnownVectors() {
        XCTAssertEqual(SHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256.hex(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testMatchesIgnoresCaseAndSeparators() {
        let data = Data("abc".utf8)
        XCTAssertTrue(SHA256.matches(data, expectedHex: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"))
        XCTAssertTrue(SHA256.matches(data, expectedHex: "ba:78:16:bf:8f:01:cf:ea:41:41:40:de:5d:ae:22:23:b0:03:61:a3:96:17:7a:9c:b4:10:ff:61:f2:00:15:ad"))
        XCTAssertFalse(SHA256.matches(data, expectedHex: "ba7816"))
        XCTAssertFalse(SHA256.matches(Data("abd".utf8), expectedHex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    }
}
