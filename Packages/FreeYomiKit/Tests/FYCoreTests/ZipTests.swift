import XCTest
@testable import FYCore

func fakePNG(_ seed: UInt8 = 1, size: Int = 64) -> Data {
    var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    d.append(Data(repeating: seed, count: size))
    return d
}

func fakeJPEG(_ seed: UInt8 = 2) -> Data {
    var d = Data([0xFF, 0xD8, 0xFF, 0xE0])
    d.append(Data(repeating: seed, count: 60))
    return d
}

final class ZipTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ data: Data, _ name: String = "a.zip") throws -> URL {
        let u = dir.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    func testRoundTripStoredAndDeflate() throws {
        var w = ZipWriter()
        let big = Data((0..<100_000).map { UInt8($0 % 7) })
        try w.add(path: "pasta/página 1.png", data: fakePNG(), compress: false)
        try w.add(path: "pasta/02.bin", data: big, compress: true)
        let zip = try ZipArchive(url: try write(w.finish()))
        XCTAssertEqual(zip.entries.count, 2)
        XCTAssertEqual(zip.entries[0].safePath, "pasta/página 1.png")
        XCTAssertEqual(try zip.data(for: zip.entries[0]), fakePNG())
        XCTAssertEqual(try zip.data(for: zip.entries[1]), big)
        XCTAssertNotNil(zip.entry(path: "PASTA/02.BIN"))
    }

    func testZipSlipNamesAreMarkedUnsafe() throws {
        var w = ZipWriter()
        try w.add(path: "../../etc/passwd", data: Data("x".utf8))
        try w.add(path: "/abs.png", data: fakePNG())
        let zip = try ZipArchive(url: try write(w.finish()))
        XCTAssertTrue(zip.entries.allSatisfy { $0.safePath == nil })
    }

    func testCorruptedCRCIsDetected() throws {
        var w = ZipWriter()
        try w.add(path: "a.png", data: fakePNG(), compress: false)
        var bytes = [UInt8](w.finish())
        bytes[30 + 5 + 10] ^= 0xFF // altera um byte do conteúdo (após cabeçalho local + nome "a.png")
        let zip = try ZipArchive(url: try write(Data(bytes)))
        XCTAssertThrowsError(try zip.data(for: zip.entries[0])) { error in
            XCTAssertTrue(error.localizedDescription.contains("CRC"))
        }
    }

    func testGarbageAndTruncatedFilesAreRejected() throws {
        XCTAssertThrowsError(try ZipArchive(url: try write(Data(repeating: 0x41, count: 1000), "lixo.zip")))
        var w = ZipWriter()
        try w.add(path: "a.png", data: fakePNG())
        let full = w.finish()
        XCTAssertThrowsError(try ZipArchive(url: try write(full.prefix(full.count - 30), "cortado.zip")))
    }

    func testEntryLimitsProtectAgainstBombs() throws {
        var w = ZipWriter()
        try w.add(path: "bomba.bin", data: Data(count: 5_000_000))
        let url = try write(w.finish())
        var limits = ZipArchive.Limits()
        limits.maxEntrySize = 1_000_000
        XCTAssertThrowsError(try ZipArchive(url: url, limits: limits))
        limits = ZipArchive.Limits()
        limits.maxCompressionRatio = 10
        XCTAssertThrowsError(try ZipArchive(url: url, limits: limits)) { error in
            XCTAssertTrue(error.localizedDescription.contains("compressão"))
        }
    }

    func testRawInflateRejectsSizeMismatch() throws {
        let compressed = try RawInflate.deflate(Data(repeating: 1, count: 1000))
        XCTAssertEqual(try RawInflate.inflate(compressed, expectedSize: 1000).count, 1000)
        XCTAssertThrowsError(try RawInflate.inflate(compressed, expectedSize: 999))
        XCTAssertThrowsError(try RawInflate.inflate(compressed, expectedSize: 1001))
    }
}

final class FileUtilitiesTests: XCTestCase {
    func testNaturalOrder() {
        let sorted = ["p10.jpg", "p2.jpg", "P1.jpg", "p02b.jpg", "capa.jpg"].sorted(by: NaturalOrder.less)
        XCTAssertEqual(sorted, ["capa.jpg", "P1.jpg", "p2.jpg", "p02b.jpg", "p10.jpg"])
        XCTAssertEqual(["Vol 10", "Vol 9", "Vol 1"].sorted(by: NaturalOrder.less), ["Vol 1", "Vol 9", "Vol 10"])
    }

    func testFirstNumber() {
        XCTAssertEqual(NaturalOrder.firstNumber(in: "Cap. 012.5 - Fim"), 12.5)
        XCTAssertEqual(NaturalOrder.firstNumber(in: "Capítulo 7"), 7)
        XCTAssertNil(NaturalOrder.firstNumber(in: "Extra"))
    }

    func testImageDetection() {
        XCTAssertEqual(ImageFormat.detect(fakePNG()), .png)
        XCTAssertEqual(ImageFormat.detect(fakeJPEG()), .jpeg)
        var webp = Data("RIFF".utf8); webp.append(Data([0, 0, 0, 0])); webp.append(Data("WEBPVP8 ".utf8))
        XCTAssertEqual(ImageFormat.detect(webp), .webp)
        XCTAssertNil(ImageFormat.detect(Data("<html></html>".utf8)))
        XCTAssertTrue(ImageFormat.looksLikeImageName("vol/001.JPG"))
        XCTAssertFalse(ImageFormat.looksLikeImageName("__MACOSX/vol/._001.jpg"))
        XCTAssertFalse(ImageFormat.looksLikeImageName("notas.txt"))
    }

    func testDiskCacheEvictsLeastRecentlyUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskCache(directory: dir, maxBytes: 2_500)
        cache.store(Data(count: 1_000), for: "a")
        cache.store(Data(count: 1_000), for: "b")
        cache.store(Data(count: 1_000), for: "c")
        let old = Date(timeIntervalSinceNow: -100)
        for (k, offset) in [("a", 30.0), ("b", 10.0), ("c", 20.0)] {
            try FileManager.default.setAttributes([.modificationDate: old.addingTimeInterval(offset)],
                                                  ofItemAtPath: dir.appendingPathComponent(DiskCache.fileName(for: k)).path)
        }
        XCTAssertEqual(cache.trim(), 1)
        XCTAssertNil(cache.data(for: "b"), "o menos usado sai primeiro")
        XCTAssertNotNil(cache.data(for: "a"))
        XCTAssertLessThanOrEqual(cache.totalBytes, 2_500)
        XCTAssertNotEqual(DiskCache.fileName(for: "x"), DiskCache.fileName(for: "y"))
    }
}
