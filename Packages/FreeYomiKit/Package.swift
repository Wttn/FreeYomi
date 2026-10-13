// swift-tools-version:5.9
//
// FreeYomiKit — núcleo multiplataforma do FreeYomi.
//
// Este pacote NÃO depende de UIKit/SwiftUI. Ele compila e roda os testes em
// macOS, iOS e também em Linux (o que permite validar a lógica de negócio a
// partir de um ambiente Windows via WSL/Docker ou no job Linux do CI).
//
// Dependências externas: nenhuma. Apenas as bibliotecas de sistema
// `sqlite3` e `zlib` (domínio público / licença zlib), já presentes no SDK do iOS.

import PackageDescription

let package = Package(
    name: "FreeYomiKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FreeYomiKit", targets: ["FYCore", "FYDomain", "FYData", "FYSources", "FYServices"]),
    ],
    targets: [
        // Bibliotecas de sistema
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
        ),
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"])]
        ),

        // Utilitários, erros, gzip, decodificador protobuf
        .target(name: "FYCore", dependencies: ["CZlib"]),

        // Entidades e regras de negócio
        .target(name: "FYDomain", dependencies: ["FYCore"]),

        // Persistência SQLite, migrações e repositórios
        .target(name: "FYData", dependencies: ["FYCore", "FYDomain", "CSQLite"]),

        // Protocolo de fontes, fonte demonstrativa, catálogo Keiyoushi
        .target(name: "FYSources", dependencies: ["FYCore", "FYDomain"]),

        // Casos de uso que combinam fontes e persistência
        .target(name: "FYServices", dependencies: ["FYCore", "FYDomain", "FYData", "FYSources"]),

        .testTarget(name: "FYCoreTests", dependencies: ["FYCore"]),
        .testTarget(name: "FYDataTests", dependencies: ["FYData", "FYDomain"]),
        .testTarget(name: "FYSourcesTests", dependencies: ["FYSources", "FYCore", "FYDomain"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "FYServicesTests", dependencies: ["FYServices", "FYData", "FYSources", "FYDomain", "FYCore"]),
    ]
)
