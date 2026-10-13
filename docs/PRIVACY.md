# Privacidade, segurança e permissões

## Dados

| Dado | Onde fica | Sai do aparelho? |
|---|---|---|
| Biblioteca, capítulos, categorias | SQLite em `Application Support/FreeYomi/` | Não |
| Histórico, progresso, tempo de leitura | SQLite | Não (o modo anônimo deixa de registrá-los) |
| Preferências | SQLite (JSON) | Não |
| Cache do catálogo de extensões | `Caches/catalog/` | Não |

Não existem conta, servidor próprio, telemetria, SDK de análise ou publicidade.

## Rede

O app só faz requisições quando:

1. o usuário abre **Explorar › Extensões** (download do índice de metadados por HTTPS);
2. o usuário navega por uma fonte online (nenhuma na Fase 1, além da demo, que é local).

Salvaguardas em `FYCore`:

- `URLPolicy.validateRemote`: só `https://`, validado também na URL final após redirecionamentos;
- limite de tamanho das respostas (32 MB) e do conteúdo descomprimido (64 MB);
- `Redactor`: remove usuário, senha e parâmetros como `token`/`api_key` de URLs antes de qualquer mensagem de erro;
- sessão `URLSession` efêmera (sem cookies persistentes nem cache HTTP).

## Código de terceiros

Nenhum. O app não baixa nem executa APK, JAR, JavaScript ou qualquer outro código. Extensões do catálogo são apenas listadas.

## Arquivos (Fase 2)

A importação de CBZ/ZIP usará `PathSanitizer.safeRelativePath`, que bloqueia `..`, caminhos absolutos e letras de unidade ("zip slip"), além de limites de tamanho por entrada e total.

## Permissões do iOS

| Permissão | Solicitada? | Motivo |
|---|---|---|
| Rede | Implícita (sem diálogo no iOS) | Catálogo e fontes |
| Fotos, câmera, microfone, localização, contatos, rastreamento (ATT) | **Não** | — |
| Arquivos | Fase 2, via seletor do sistema (`UIDocumentPicker`): acesso só ao que o usuário escolher | Importar CBZ/ZIP/EPUB |
| Notificações | Futuro, opcional | Avisar capítulos novos |

`ITSAppUsesNonExemptEncryption = false`: o app usa apenas o TLS do sistema.
