# Como contribuir

Obrigado pelo interesse! O FreeYomi aceita contribuições de código, documentação, testes, acessibilidade e design.

## Regras do projeto (não negociáveis)

1. **Nada pago:** nenhum PR pode adicionar anúncios, compras no app, assinaturas, moedas, créditos, limites artificiais ou bloqueio de funcionalidades.
2. **Sem rastreamento:** nada de SDKs de análise, telemetria ou publicidade. Requisições de rede só para o que o usuário pediu.
3. **Sem código remoto:** o app não pode baixar e executar código (APK, JAR, JS, WASM…). Fontes são adaptadores Swift no repositório.
4. **Sem conteúdo protegido:** não inclua capas, páginas, logos ou textos de obras ou apps de terceiros (nem em testes ou capturas).
5. **Licenças:** toda dependência nova entra em `DEPENDENCIES.md` com a licença verificada. Não copie código sem licença compatível com Apache-2.0.
6. **Honestidade na interface:** não marque como "compatível" o que não foi implementado e testado. Dados fictícios ficam sempre rotulados.

## Fluxo

1. Abra uma *issue* descrevendo a proposta (exceto para correções pequenas).
2. Crie um branch a partir de `main`.
3. Rode `scripts/test-core.ps1` (Windows/Docker) ou `scripts/test-core.sh` (WSL/Linux/macOS).
4. Abra o PR; o CI precisa ficar verde (núcleo em Linux, app e testes de interface em macOS).

## Organização do código

- Lógica de negócio, persistência e fontes vão em `Packages/FreeYomiKit`, **sem importar SwiftUI/UIKit**, para que rodem e sejam testadas em Linux.
- A interface fica em `Features/<Módulo>` e usa componentes de `DesignSystem/`.
- Liquid Glass só pelos helpers de `DesignSystem/Glass.swift` (`fyGlass`, `fyProminentButton`…), que já cuidam do fallback.
- Migrações de banco: **nunca altere uma migração publicada**; adicione uma nova versão em `Migrator.migrations` e um teste.

## Adicionando uma fonte

1. Implemente `MangaSource` em `Packages/FreeYomiKit/Sources/FYSources/<Nome>Source.swift`.
2. Use `HTTPClient` (injetável) e `URLPolicy.validateRemote`; nunca registre credenciais (use `Redactor`).
3. Escreva testes com `StubHTTP` (sem rede).
4. Registre a fonte em `SourceRegistry.makeDefault()`. Se ela corresponder a uma extensão do catálogo, adicione o `packageName` em `CompatibilityResolver.nativeAdapters`.
5. Confirme que os termos de uso da fonte permitem esse acesso.

## Estilo

- Swift API Design Guidelines; 4 espaços; linhas de até ~120 colunas.
- Textos da interface em português do Brasil; documentação em português.
- Acessibilidade: rótulos em botões só com ícone, Dynamic Type, respeito a Reduce Motion.
