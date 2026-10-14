#ifndef FYJVM_H
#define FYJVM_H

/// Inicia (uma vez) a JVM embutida e chama `public static String run(String)`
/// da classe `className` (com pontos ou barras), carregada de `classPath`.
/// O resultado (ou o erro) é copiado para `out`. Devolve 0 em caso de sucesso.
int fy_jvm_run(const char *classPath, const char *className, const char *argument, char *out, int outLength);

#endif
