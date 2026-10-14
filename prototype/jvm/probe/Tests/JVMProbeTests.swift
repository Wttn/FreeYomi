import XCTest
@testable import JVMProbe

final class JVMProbeTests: XCTestCase {
    /// A JVM sobe dentro do app, executa uma classe do classpath e carrega
    /// outra classe de um .jar fora do classpath (como uma extensão).
    func testJVMStartsAndLoadsJarDynamically() {
        let r = JVMProbe.run()
        print("FYJVM-RESULT: [\(r.code)] \(r.output)")
        XCTAssertEqual(r.code, 0, r.output)
        XCTAssertTrue(r.output.contains("plugin: ok"), r.output)
    }
}
