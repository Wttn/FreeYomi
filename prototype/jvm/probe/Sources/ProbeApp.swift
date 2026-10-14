import SwiftUI

/// App de teste da JVM embutida. Não faz parte do FreeYomi.
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

enum JVMProbe {
    static var jars: URL { Bundle.main.resourceURL!.appendingPathComponent("jars") }

    /// Classpath único (a JVM é criada uma vez por processo): classe de teste + runtime das extensões.
    static var classPath: String {
        ["hello.jar", "fy-runtime.jar"].map { jars.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .joined(separator: ":")
    }

    static func call(_ className: String, _ argument: String) -> (code: Int32, output: String) {
        var buffer = [CChar](repeating: 0, count: 65_536)
        let started = Date()
        let code = fy_jvm_run(classPath, className, argument, &buffer, Int32(buffer.count))
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        return (code, String(cString: buffer) + " | \(seconds) s")
    }

    static func run() -> (code: Int32, output: String) {
        call("Hello", jars.appendingPathComponent("plugin.jar").path)
    }

    /// Carrega uma extensão real (.jar + classe lida do AndroidManifest) e lista os populares.
    static func runExtension() -> (code: Int32, output: String)? {
        let info = jars.appendingPathComponent("extension.txt")
        guard let text = try? String(contentsOf: info, encoding: .utf8) else { return nil }
        let className = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fy-runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let ext = jars.appendingPathComponent("extension.jar").path
        return call("freeyomi.FYHost", "\(data.path)|\(ext)|\(className)")
    }
}

struct ProbeView: View {
    @State private var output = "Toque para iniciar a JVM."
    @State private var running = false

    var body: some View {
        VStack(spacing: 16) {
            Text("JVM embutida (OpenJDK Zero)").font(.headline)
            Text(output).font(.caption.monospaced()).textSelection(.enabled).padding()
            Button(running ? "Executando…" : "Iniciar JVM") {
                running = true
                DispatchQueue.global().async {
                    let r = JVMProbe.run()
                    DispatchQueue.main.async { output = "[\(r.code)] \(r.output)"; running = false }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
        .padding()
    }
}
