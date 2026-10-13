# Compilar a partir do Windows

Nenhum Mac físico é necessário. O fluxo:

```
Windows (VS Code + Git + Docker/WSL)  ──push──▶  GitHub Actions
   │  edita código                                  ├─ Linux: testes do núcleo
   │  roda testes do núcleo                         └─ macOS 26 / Xcode 26:
   │                                                     xcodegen → testes de interface → .ipa sem assinatura
   └──◀── baixa o artefato .ipa ──┘
          assina e instala no iPhone (Sideloadly/AltStore) — ver INSTALL_IPHONE.md
```

## 1. Ferramentas no Windows

| Ferramenta | Para quê |
|---|---|
| [Git for Windows](https://git-scm.com/download/win) | Versionamento |
| [VS Code](https://code.visualstudio.com/) + extensões de `.vscode/extensions.json` | Edição (a extensão Swift oferece realce e, via WSL, autocompletar do núcleo) |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) **ou** WSL 2 com Ubuntu | Rodar `swift test` do núcleo |
| Conta no GitHub | Repositório público + CI gratuito para repositórios públicos |

## 2. Testes locais do núcleo

Com Docker Desktop:

```powershell
cd C:\Users\<você>\Documents\Claude\FreeYomi
powershell -ExecutionPolicy Bypass -File scripts\test-core.ps1
# baixando também o índice real do Keiyoushi:
powershell -ExecutionPolicy Bypass -File scripts\test-core.ps1 -Live
```

Com WSL (Ubuntu 24.04), uma única vez:

```bash
sudo apt-get install -y libsqlite3-dev zlib1g-dev
# instale o Swift 6.x pelo instalador oficial "swiftly": https://www.swift.org/install/linux/
```

Depois: `bash scripts/test-core.sh`. No VS Code também existem as tarefas *Testes do núcleo (Docker)* e *(WSL)* (`Ctrl+Shift+P › Run Task`).

> A camada SwiftUI (`App/`, `DesignSystem/`, `Features/`) só compila em macOS, porque depende do SDK do iOS. Por isso toda a lógica testável fica no pacote `FreeYomiKit`.

## 3. Criar o repositório e acionar o CI

```powershell
cd C:\Users\<você>\Documents\Claude\FreeYomi
git init -b main
git add .
git commit -m "FreeYomi: Fase 1 (fundação)"
# crie um repositório PÚBLICO vazio no GitHub (ex.: <usuario>/FreeYomi) e então:
git remote add origin https://github.com/<usuario>/FreeYomi.git
git push -u origin main
```

O workflow `.github/workflows/ci.yml` roda a cada push e PR:

1. **Núcleo (Linux):** `swift test` no contêiner `swift:6.1-noble`, mais o teste ao vivo do índice (não bloqueante).
2. **App iOS (Xcode 26):** seleciona o Xcode 26 → `brew install xcodegen` → `xcodegen generate` → `swift test` no macOS → `xcodebuild test` no simulador de iPhone mais recente → `xcodebuild archive` sem assinatura → artefato **`FreeYomi-unsigned-ipa`**.

Para baixar o `.ipa`: GitHub › aba **Actions** › execução mais recente › seção **Artifacts**.

Se o runner `macos-26` não existir na sua conta, troque `runs-on: macos-26` por `macos-latest` (o passo "Selecionar Xcode 26" escolhe o Xcode 26 se estiver instalado). Sem Xcode 26 o app ainda compila, mas usa o visual de fallback (sem Liquid Glass).

## 4. Alternativas de macOS remoto

- **Codemagic**, **Bitrise**: CI com macOS e plano gratuito limitado; os mesmos comandos do `ci.yml` funcionam.
- **Mac na nuvem** (aluguel por hora, como MacinCloud ou AWS EC2 Mac): útil para depurar com o Xcode interativamente quando necessário.

## 5. Comandos equivalentes em um Mac (referência)

```bash
brew install xcodegen
xcodegen generate
open FreeYomi.xcodeproj                      # Xcode 26
(cd Packages/FreeYomiKit && swift test)
xcodebuild test -project FreeYomi.xcodeproj -scheme FreeYomi \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
