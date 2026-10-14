#ifndef FYJVM_H
#define FYJVM_H

/// Ponte C para a JVM embutida (OpenJDK Mobile, interpretador Zero).
/// Só existe de verdade quando o app é compilado com FY_JVM=1 (o CI liga as
/// bibliotecas da JVM); sem isso, `fy_jvm_available()` devolve 0.

typedef void (*fy_jvm_callback)(void *context, char *result);

/// 1 se a JVM foi ligada a esta compilação do app.
int fy_jvm_available(void);

/// Chama `freeyomi.FYHost.call(String): String` numa thread própria (pilha de
/// 32 MB) e entrega a resposta JSON em `callback`, que deve liberá-la com
/// `fy_jvm_free`. A JVM é criada na primeira chamada, com `classPath`.
void fy_jvm_call_async(const char *classPath, const char *request, void *context, fy_jvm_callback callback);

void fy_jvm_free(char *text);

#endif
