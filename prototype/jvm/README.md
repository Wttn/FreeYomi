# Protótipo: JVM embutida (modelo do Tachimanga)

## Como o Tachimanga roda extensões no iPhone

Ele embute uma máquina virtual Java no app e roda dentro dela um fork do
Suwayomi/Tachidesk-Server: [`tachimanga/Tachidesk-Server`](https://github.com/tachimanga/Tachidesk-Server),
MPL-2.0. Esse servidor baixa o `.jar` de cada extensão (por isso o `index.pb`
traz o campo `jarUrl` 501) e executa o código Kotlin da extensão no aparelho.
Rede, WebView, Bitmap e QuickJS passam por pontes nativas (`NativeNet`,
`WebView.createNativeWebview` etc.). A parte da máquina Java para iOS não é
pública.

## Caminho do FreeYomi

1. **JVM sem JIT para iOS:** o projeto oficial [OpenJDK Mobile](https://github.com/openjdk/mobile)
   compila `libjvm.a` estático para iOS com o interpretador **Zero**, que não
   gera código de máquina em tempo de execução. Workflow:
   `.github/workflows/jvm-ios.yml`. ← **etapa atual**
2. **Prova de vida:** um alvo de teste que inicia a JVM (`JNI_CreateJavaVM`)
   dentro do app e carrega uma classe de um `.jar` baixado.
3. **Runtime das extensões:** biblioteca de compatibilidade Android e a camada
   de fontes do Suwayomi/Tachimanga (MPL-2.0, mantida em arquivos MPL),
   `extensions-lib` 1.4/1.5/1.6, OkHttp, Jsoup, RxJava, Injekt e Kotlin.
4. **Ponte com o app:** listar, buscar, detalhes, capítulos e páginas via JNI
   (JSON) para um `MangaSource` em Swift; instalar a partir dos repositórios
   que o usuário adicionou.

## Riscos conhecidos

- **Desempenho:** o Zero é um interpretador, então as extensões vão rodar bem
  mais devagar que no Android. Inicialização e memória precisam ser medidas.
- **Licença:** o HotSpot (`libjvm`) é GPLv2. Ligado estaticamente, o app
  inteiro passa a ter obrigações da GPLv2, que é incompatível com a
  Apache-2.0 atual. Para uso pessoal (sideload) não há distribuição. Para
  publicar o .ipa, será preciso decidir a licença.
- **App Store:** baixar e executar código de extensões contraria a diretriz
  2.5.2. Na prática, a distribuição seria por sideload.
- **Segurança:** extensões rodariam com o acesso que a JVM tiver dentro do
  app. O plano é isolá-las da biblioteca e do Keychain (sem ponte para esses dados).
