import Foundation
import FYCore
import FYSources

/// A JVM embutida no app (OpenJDK Mobile + runtime do Tachidesk-Server do
/// Tachimanga), vista pelo núcleo como um `JVMBridge`.
///
/// Arquivos no pacote do app (colocados pelo CI):
///  - `lib/`  — JAVA_HOME (classes do Java em imagem explodida, segurança, fusos);
///  - `jars/fy-runtime.jar` — runtime de compatibilidade + `freeyomi.FYHost`.
/// A JVM só inicia na primeira chamada (quando uma fonte dessas é usada).
final class EmbeddedJVM: JVMBridge, @unchecked Sendable {
    static let shared = EmbeddedJVM()

    /// Pasta de dados do runtime (preferências das fontes, cache do OkHttp…).
    let dataRoot: URL
    private let runtimeJar: URL?
    private let javaHomeReady: Bool
    private let lock = NSLock()
    private var startTask: Task<Void, Error>?
    /// Pilha Java do último erro (diagnóstico).
    private(set) var lastTrace: String?

    init(bundle: Bundle = .main) {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        dataRoot = support.appendingPathComponent("FreeYomi/JVM", isDirectory: true)
        let jar = bundle.bundleURL.appendingPathComponent("jars/fy-runtime.jar")
        runtimeJar = fm.fileExists(atPath: jar.path) ? jar : nil
        // O HotSpot estático do iOS usa <App>.app/lib como java.home.
        // Classes do Java num único arquivo jimage: <app>/lib/lib/modules.
        javaHomeReady = fm.fileExists(atPath: bundle.bundleURL.appendingPathComponent("lib/lib/modules").path)
    }

    var isAvailable: Bool { fy_jvm_available() != 0 && runtimeJar != nil && javaHomeReady }

    /// Por que o runtime não está disponível (para a tela de configurações).
    var unavailableReason: String? {
        if fy_jvm_available() == 0 { return "Esta compilação do app não inclui a JVM." }
        if runtimeJar == nil { return "O runtime de extensões (fy-runtime.jar) não está no pacote do app." }
        if !javaHomeReady { return "As classes do Java não estão no pacote do app." }
        return nil
    }

    func call(_ request: [String: Any]) async throws -> Any {
        guard isAvailable else {
            throw FYError.unsupported(unavailableReason ?? "runtime de extensões indisponível")
        }
        try await start()
        return try await send(request)
    }

    /// Cria a JVM e inicia o runtime (uma vez; se falhar, a próxima chamada tenta de novo).
    private func start() async throws {
        let task: Task<Void, Error> = lock.withLock {
            if let startTask { return startTask }
            let root = dataRoot
            let t = Task {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                _ = try await self.send(["op": "init", "root": root.path])
            }
            startTask = t
            return t
        }
        do {
            try await task.value
        } catch {
            lock.withLock { startTask = nil }
            throw error
        }
    }

    private final class Box {
        let continuation: CheckedContinuation<String, Never>
        init(_ c: CheckedContinuation<String, Never>) { continuation = c }
    }

    private func send(_ request: [String: Any]) async throws -> Any {
        guard let runtimeJar else { throw FYError.unsupported("runtime ausente") }
        let body = try JSONSerialization.data(withJSONObject: request)
        let json = String(decoding: body, as: UTF8.self)
        let response: String = await withCheckedContinuation { continuation in
            let context = Unmanaged.passRetained(Box(continuation)).toOpaque()
            fy_jvm_call_async(runtimeJar.path, json, context) { context, result in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
                let text = result.map { String(cString: $0) } ?? ""
                fy_jvm_free(result)
                box.continuation.resume(returning: text)
            }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8), options: [.fragmentsAllowed]))
                as? [String: Any] else {
            throw FYError.invalidData("resposta ilegível do runtime de extensões")
        }
        if (object["ok"] as? Bool) == true { return object["result"] ?? NSNull() }
        let message = (object["error"] as? String) ?? "erro desconhecido"
        if let trace = object["trace"] as? String {
            lock.withLock { lastTrace = trace }
            print("[FreeYomi JVM] \(message)\n\(trace)")
        }
        throw FYError.source(message)
    }
}
