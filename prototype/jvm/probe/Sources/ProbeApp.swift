import SwiftUI

/// App de teste da JVM embutida. Não faz parte do FreeYomi.
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

enum JVMProbe {
    static func run() -> (code: Int32, output: String) {
        guard let jars = Bundle.main.resourceURL?.appendingPathComponent("jars") else { return (-1, "sem recursos") }
        let hello = jars.appendingPathComponent("hello.jar").path
        let plugin = jars.appendingPathComponent("plugin.jar").path
        var buffer = [CChar](repeating: 0, count: 16_384)
        let started = Date()
        let code = fy_jvm_run(hello, "Hello", plugin, &buffer, Int32(buffer.count))
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        return (code, String(cString: buffer) + " | \(seconds) s")
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
