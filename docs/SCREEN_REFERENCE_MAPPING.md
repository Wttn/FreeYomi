# Mapeamento das capturas de referência

As cinco capturas fornecidas (iPhone, tema escuro, iOS 26 com Liquid Glass, app Tachimanga em pt-BR) orientam a estrutura das telas. **As imagens não são incluídas no repositório**: elas contêm capas de obras protegidas e a interface de um app sem licença aberta. Cada uma é identificada abaixo pelo conteúdo.

## Padrões comuns (todas as capturas)

| Elemento observado | Decisão no FreeYomi |
|---|---|
| Fundo quase preto (#141414–#1C1C1E), texto branco, secundários em cinza | Cores semânticas do sistema (`systemBackground`, `.secondary`), corretas também no tema claro |
| Título grande à esquerda, na **mesma linha** dos botões | `navigationTitle` + `toolbarTitleDisplayMode(.inlineLarge)` (nativo) |
| Botões do topo em cápsulas de vidro agrupadas (ex.: [filtro] [busca · mais]) | `ToolbarItem` + `ToolbarItemGroup` nativos; no iOS 26 o sistema desenha as cápsulas Liquid Glass e agrupa os itens |
| Ícone de nuvem ao lado do título (estado de sincronização) | **Omitido**: não há sincronização na Fase 1, e mostrar o ícone sugeriria um recurso inexistente |
| Tab bar flutuante em vidro, 5 itens, item ativo com fundo em pílula e ícone/texto azul-lavanda | `TabView` nativo (vidro automático no iOS 26) + `tint` com `FYColor.accent` (#A8C2FA no escuro) + `tabBarMinimizeBehavior(.onScrollDown)` |
| Emblema vermelho "2" na aba Explorar (atualizações de extensões) | Não se aplica: não instalamos extensões. Usamos `.badge` na aba **Atualizações** com o número de capítulos novos |

## 1. Biblioteca

**Finalidade:** acesso aos títulos salvos.
**Componentes:** título "Biblioteca"; botões [filtro] e [busca, ⋯]; grade de **2 colunas** com capas grandes (proporção ≈ 0,75, cantos ≈ 12 pt, espaçamento ≈ 8 pt); título em branco sobreposto na base com degradê escuro; emblema de não lidos no canto superior esquerdo (pílula azul-clara, texto escuro, números como 363/27/419/170).

| Requisito | Implementação |
|---|---|
| Grade com título sobreposto | `LibraryGridCell` (modo "Grade"); modos "Grade confortável" (título abaixo) e "Lista" |
| Emblema de não lidos | `UnreadBadge` (`FYColor.badgeBackground` / `badgeForeground`), com opção de ocultar |
| Itens por linha | 1–6, padrão 2 (igual à captura) |
| Filtro | `LibraryOptionsSheet`: ordenação, modo de exibição, itens por linha, emblemas |
| Busca | `.searchable` acionado pelo botão de lupa |
| "⋯" | Menu: selecionar títulos (lote) e atualizar a biblioteca |
| Comportamento não visível na captura | Menu contextual (pressão longa), seleção múltipla com barra de vidro inferior, abas de categoria em "chips" — escolhas coerentes com o restante |

## 2. Atualizações

Não havia captura desta tela. Ela segue o padrão das demais (título grande, botão de atualizar no topo, lista agrupada por título) e mostra o horário da verificação, os títulos ignorados e as falhas por fonte (requisito do briefing).

## 3. Explorar

**Finalidade:** fontes de conteúdo.
**Componentes:** título "Explorar"; botões [busca, busca global, idioma]; controle segmentado em vidro **Fontes / Extensões (2) / Migrar**; seções "Último usado", "Português", "Multi", "English"; linhas com ícone quadrado arredondado (≈ 44 pt), nome, idioma em cinza e três ações: ⚙︎ configurar, 📌 fixar, ⚠︎ status.

| Requisito | Implementação |
|---|---|
| Segmentos | `Picker(.segmented)` nativo (no iOS 26 recebe o estilo do sistema) |
| Seções "Último usado" e por idioma | `SourcesListView`, a partir de `sources.last_used_at` e do idioma da fonte; seção extra "Fixadas" |
| ⚙︎ / 📌 | `SourceInfoSheet` e fixar/desafixar persistido |
| ⚠︎ (status) | Situação da fonte: "Implementada" / "Aguardando desenvolvimento" / "Incompatível (requer Android)" |
| Extensões | `ExtensionCatalogView`: índice Keiyoushi com origem, data da sincronização, filtro por idioma (padrão pt-BR), busca e classificação honesta de compatibilidade |
| Migrar | Tela informativa (Fase 3) |
| Fontes da captura (Kagane, MangaFire, MangaDex, GlobalComix…) | **Não reproduzidas.** São extensões Android; listá-las como fontes funcionais violaria a regra "não declarar suporte só porque aparece no catálogo". Elas aparecem na aba Extensões como "Requer Android" |

## 4. Histórico

**Finalidade:** retomar leituras.
**Componentes:** título "Histórico"; botões [óculos] e [busca, lixeira]; linhas com miniatura (≈ 110×160 pt, cantos arredondados), título em negrito, nome do capítulo em cinza (truncado), ícone de livro + tempo de leitura ("6 min", "48 min"), relógio + data relativa ("3 dias atrás") ou absoluta ("1 de out. de 2026"); lixeira por linha à direita; placeholder de imagem quebrada quando a capa não carrega.

| Requisito | Implementação |
|---|---|
| Linha completa | `HistoryRow`: miniatura, título, capítulo, `book.closed` + duração (só ≥ 1 min, como na captura, em que algumas linhas não têm duração), `clock` + data relativa |
| Placeholder de capa | `CoverPlaceholder` (ícone `photo.badge.exclamationmark` sobre fundo cinza) |
| Lixeira por linha | Diálogo de confirmação: remover o capítulo ou todo o título |
| Lixeira geral | "Limpar histórico" com confirmação (requisito do briefing) |
| Óculos | Interpretado como **modo anônimo** (não registrar leituras), alternável no topo e em Segurança |
| Progresso | Barra de progresso na linha (o briefing pede o progresso; a captura não mostra) |

## 5. Mais

**Finalidade:** configurações e informações.
**Componentes:** título centralizado "Mais"; faixa "Assinatura Premium ativa" no topo; lista com ícones à esquerda e chevrons: Geral, Aparência, Biblioteca, Leitor, Sincronizar 👑, Rastreamento 👑, Extensões, Backup e Restauração, Segurança, Informações de leitura, Transferências; separador; Compartilhar, Ajuda, Sobre.

| Requisito | Implementação |
|---|---|
| Mesma ordem e agrupamento | `MoreView`, com os mesmos rótulos |
| 👑 coroas premium e "Assinatura Premium ativa" | **Removidos de propósito.** No lugar, o cartão "Gratuito e open source — sem anúncios, sem assinaturas, sem recursos bloqueados". Teste de interface garante que não há texto de assinatura |
| Itens não implementados | `PlannedFeatureView` explica o que será feito e em qual fase. Nenhum item leva a uma tela falsa |
| Downloads | "Transferências" corresponde ao módulo Downloads do briefing |

## 6. Configurações › Biblioteca

**Componentes:** botão voltar em círculo de vidro; título centralizado; cabeçalhos de seção em **azul-lavanda** ("Categorias", "Exibir", "Atualização"); linhas com ícone, título e subtítulo cinza; controle **− 2 +** com botões circulares azul-claros; interruptores.

| Linha da captura | Implementação |
|---|---|
| Editar Categoria — "0 categoria" | `CategoriesEditorView` (criar, renomear, excluir, reordenar) |
| Categoria padrão — "Sempre perguntar" | Picker com "Sempre perguntar / nenhuma" + categorias |
| Modo de exibição — "Grade" | Picker Grade / Grade confortável / Lista |
| Itens por linha − 2 + | `ItemsPerRowStepper` (botões circulares `FYColor.badgeBackground`, ajustável pelo VoiceOver) |
| Emblemas | Toggle de emblema de não lidos |
| Pular atualização de títulos — "Com status concluído" | Toggle `skipUpdatingCompleted` (padrão ligado, igual à captura) |
| Categorias excluídas | Fase 4 (junto com o agendamento de atualizações) |
| Atualizações continuam em segundo plano | Linha informativa: Fase 4 (BGTaskScheduler) |
| Atualização automática / Atualizar metadados automaticamente | Toggle `autoRefreshOnOpen` (metadados: Fase 4) |
| Cabeçalhos coloridos | `FYSectionHeader` com `FYColor.sectionHeader` |

## Acessibilidade aplicada a todas as telas

- Dynamic Type: apenas estilos de texto do sistema (`.headline`, `.caption`…), sem tamanhos fixos em textos.
- VoiceOver: células da grade com rótulo combinado ("título, N não lidos, último lido: …"), ícones decorativos ocultos, rótulos em todos os botões só com ícone, controle de itens por linha ajustável.
- Reduce Motion: o leitor desativa animações de troca de página e dos controles.
- Contraste: emblema com texto escuro sobre fundo claro; títulos sobre capas com degradê de 75% de opacidade.
