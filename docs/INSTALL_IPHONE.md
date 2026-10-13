# Instalar no iPhone (a partir do Windows)

O CI produz `FreeYomi-unsigned.ipa` (**sem assinatura**). O iOS só instala apps assinados, então você assina o `.ipa` com **a sua** conta Apple. Nenhum certificado fica no repositório.

## Opção A — Apple ID gratuito + Sideloadly (mais simples no Windows)

Pré-requisitos: iPhone com iOS 17+ e cabo USB; [iTunes para Windows](https://www.apple.com/itunes/) (versão do site da Apple, não a da Microsoft Store, para que o driver USB funcione); [Sideloadly](https://sideloadly.io/) (gratuito, de terceiros).

1. Baixe o artefato `FreeYomi-unsigned-ipa` do GitHub Actions e extraia o `.ipa`.
2. Conecte o iPhone e confie no computador.
3. Abra o Sideloadly, arraste o `.ipa`, informe seu Apple ID e clique em **Start**.
4. No iPhone: **Ajustes › Privacidade e Segurança › Modo de Desenvolvedor** → ativar (o aparelho reinicia).
5. **Ajustes › Geral › VPN e Gerenciamento de Dispositivos** → confie no seu Apple ID.
6. Abra o FreeYomi.

Limites da Apple para contas gratuitas: a assinatura vale **7 dias** (é preciso reassinar; o Sideloadly pode automatizar isso), até 3 apps instalados assim e alguns *entitlements* indisponíveis. Isso não afeta o FreeYomi na Fase 1.

## Opção B — AltStore / SideStore

Instale o [AltServer para Windows](https://altstore.io/) (ou o SideStore, que dispensa o computador após a configuração inicial) e abra o `.ipa` pelo app no iPhone. As mesmas regras de 7 dias se aplicam.

## Opção C — Apple Developer Program (pago à Apple)

Com uma conta paga da Apple (taxa anual da Apple, não do FreeYomi) você pode:

- assinar por 1 ano e distribuir via **TestFlight**;
- automatizar a assinatura no CI.

Configuração (a ser automatizada em uma fase futura, ainda não implementada no workflow):

1. Em developer.apple.com, crie o App ID `io.github.freeyomi.app` (ou o seu prefixo) e um certificado *Apple Distribution*. Gere o CSR com OpenSSL no Windows: `openssl req -new -newkey rsa:2048 -nodes -keyout chave.key -out pedido.csr`.
2. Converta o certificado `.cer` + chave em `.p12` (`openssl pkcs12 -export ...`) e crie um *provisioning profile*.
3. Salve no repositório, como **Secrets** do GitHub (nunca em arquivos): `P12_BASE64`, `P12_PASSWORD`, `PROFILE_BASE64`, `TEAM_ID`, e uma chave da App Store Connect API para envio ao TestFlight.
4. Um job de release importará esses segredos em um *keychain* temporário do runner, fará o `archive` assinado e enviará ao TestFlight.

## Teste manual no aparelho (checklist do critério 14)

Após instalar, confirme e registre o resultado em `docs/PHASE1_REPORT.md`:

- [ ] O app abre em modo avião (sem internet).
- [ ] A biblioteca mostra os 4 títulos "Demonstração".
- [ ] Abrir um capítulo, virar páginas tocando nas laterais e deslizando.
- [ ] Trocar para "Webtoon" no menu do leitor e rolar.
- [ ] Fechar o app pelo seletor de apps, reabrir e conferir que o progresso foi mantido.
- [ ] Explorar › Extensões baixa o catálogo com internet e mostra "Mostrando cópia local" sem internet.
- [ ] Ajustes do iPhone em claro/escuro → o app acompanha (tema "Automático").
- [ ] No iOS 26: tab bar e botões em Liquid Glass.
