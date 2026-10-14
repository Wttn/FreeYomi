import Foundation

/// Erros do núcleo com mensagens compreensíveis em português.
///
/// As mensagens nunca incluem credenciais: URLs passam por `Redactor` antes
/// de entrar em uma mensagem de erro.
public enum FYError: Error, Equatable, Sendable {
    /// Falha de transporte (sem internet, timeout, DNS…).
    case network(String)
    /// Servidor respondeu com status HTTP inesperado.
    case httpStatus(Int, url: String)
    /// Dados recebidos ou lidos não estão no formato esperado.
    case invalidData(String)
    /// Falha no banco de dados local.
    case database(String)
    /// Recurso não encontrado.
    case notFound(String)
    /// Funcionalidade não suportada no iOS ou ainda não implementada.
    case unsupported(String)
    /// URL rejeitada pela validação de segurança.
    case insecureURL(String)
    /// Operação cancelada pelo usuário ou pelo sistema.
    case cancelled
    /// Erro relatado pela extensão (site fora do ar, layout mudou…).
    case source(String)
}

extension FYError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Não foi possível conectar. Verifique sua internet e tente novamente. (\(detail))"
        case .httpStatus(let code, let url):
            return "O servidor respondeu com o código \(code) para \(url)."
        case .invalidData(let detail):
            return "Os dados recebidos são inválidos: \(detail)"
        case .database(let detail):
            return "Erro no banco de dados local: \(detail)"
        case .notFound(let what):
            return "Não encontrado: \(what)"
        case .unsupported(let detail):
            return "Não suportado: \(detail)"
        case .insecureURL(let url):
            return "Endereço recusado por segurança (apenas HTTPS é permitido): \(url)"
        case .cancelled:
            return "Operação cancelada."
        case .source(let detail):
            return "A extensão relatou um erro: \(detail)"
        }
    }
}
