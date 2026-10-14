// Ponte mínima para a JVM embutida (OpenJDK Mobile, interpretador Zero, estático).
//
// Cada chamada roda numa thread própria com pilha grande: o Zero interpreta em
// C++ e usa bastante pilha (a thread principal do iOS tem só 1 MB). A JVM é
// criada uma única vez; as demais chamadas só anexam a thread a ela.
#include "fyjvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char *classPath;
    char *request;
    void *context;
    fy_jvm_callback callback;
} fy_job;

// Resposta de erro no mesmo formato JSON do FYHost.
static char *fy_error_json(const char *message) {
    size_t n = strlen(message);
    char *out = malloc(n * 6 + 32);
    if (!out) return NULL;
    char *p = out;
    p += sprintf(p, "{\"ok\":false,\"error\":\"");
    for (const unsigned char *s = (const unsigned char *)message; *s; s++) {
        if (*s == '"' || *s == '\\') { *p++ = '\\'; *p++ = (char)*s; }
        else if (*s < 0x20) { p += sprintf(p, "\\u%04x", *s); }
        else { *p++ = (char)*s; }
    }
    sprintf(p, "\"}");
    return out;
}

void fy_jvm_free(char *text) { free(text); }

#ifndef FY_JVM

int fy_jvm_available(void) { return 0; }

void fy_jvm_call_async(const char *classPath, const char *request, void *context, fy_jvm_callback callback) {
    (void)classPath; (void)request;
    callback(context, fy_error_json("esta compilação do app não inclui o runtime de extensões"));
}

#else

#include <jni.h>
#include <pthread.h>
#include <stdarg.h>

static JavaVM *g_vm = NULL;
static FILE *g_log = NULL;
static pthread_mutex_t g_create = PTHREAD_MUTEX_INITIALIZER;
static char g_create_error[512] = "";

int fy_jvm_available(void) { return 1; }

// A saída da JVM vai para fyjvm.log (no simulador, na pasta do usuário do Mac,
// onde o CI consegue ler mesmo se a JVM encerrar o processo).
static void fy_open_log(void) {
    if (g_log) return;
    const char *host = getenv("SIMULATOR_HOST_HOME");
    const char *tmp = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/fyjvm.log", host ? host : (tmp ? tmp : "/tmp"));
    g_log = fopen(path, "a");
}

static jint JNICALL fy_vfprintf(FILE *stream, const char *format, va_list args) {
    (void)stream;
    fy_open_log();
    if (!g_log) return 0;
    jint n = (jint)vfprintf(g_log, format, args);
    fflush(g_log);
    return n;
}

static void JNICALL fy_exit_hook(jint code) {
    fy_open_log();
    if (g_log) { fprintf(g_log, "\n[fyjvm] a JVM pediu exit(%d)\n", (int)code); fflush(g_log); }
}

static int fy_create_vm(const char *classPath, JNIEnv **env) {
    char cp[8192];
    snprintf(cp, sizeof cp, "-Djava.class.path=%s", classPath);
    // No iOS só o contêiner do app é gravável: /tmp não serve.
    char tmpdir[1200];
    const char *t = getenv("TMPDIR");
    snprintf(tmpdir, sizeof tmpdir, "-Djava.io.tmpdir=%s", t ? t : "/tmp");
    JavaVMOption options[] = {
        { .optionString = cp },
        { .optionString = tmpdir },
        { .optionString = "-Xmx512m" },
        { .optionString = "-Xshare:off" },
        { .optionString = "-XX:+UseSerialGC" },
        { .optionString = "-Xss4m" },
        { .optionString = "-XX:-UsePerfData" },
        { .optionString = "-Djava.awt.headless=true" },
        { .optionString = "-Dfile.encoding=UTF-8" },
        { .optionString = "vfprintf", .extraInfo = (void *)fy_vfprintf },
        { .optionString = "exit", .extraInfo = (void *)fy_exit_hook },
    };
    JavaVMInitArgs args;
    args.version = JNI_VERSION_10;
    args.nOptions = (jint)(sizeof options / sizeof options[0]);
    args.options = options;
    args.ignoreUnrecognized = JNI_TRUE;
    jint rc = JNI_CreateJavaVM(&g_vm, (void **)env, &args);
    if (rc != JNI_OK) {
        g_vm = NULL;
        snprintf(g_create_error, sizeof g_create_error, "não foi possível iniciar o runtime Java (JNI %d)", (int)rc);
        return 0;
    }
    return 1;
}

static char *fy_exception(JNIEnv *env, const char *where) {
    jthrowable t = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    char buffer[2048];
    snprintf(buffer, sizeof buffer, "%s: exceção Java", where);
    if (t) {
        jclass throwable = (*env)->FindClass(env, "java/lang/Throwable");
        jmethodID toString = throwable ? (*env)->GetMethodID(env, throwable, "toString", "()Ljava/lang/String;") : NULL;
        jstring s = toString ? (jstring)(*env)->CallObjectMethod(env, t, toString) : NULL;
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        if (s) {
            const char *chars = (*env)->GetStringUTFChars(env, s, NULL);
            snprintf(buffer, sizeof buffer, "%s: %s", where, chars);
            (*env)->ReleaseStringUTFChars(env, s, chars);
        }
    }
    return fy_error_json(buffer);
}

static char *fy_run(fy_job *job) {
    JNIEnv *env = NULL;
    pthread_mutex_lock(&g_create);
    int created_here = 0;
    if (g_vm == NULL) {
        if (g_create_error[0]) { pthread_mutex_unlock(&g_create); return fy_error_json(g_create_error); }
        if (!fy_create_vm(job->classPath, &env)) {
            pthread_mutex_unlock(&g_create);
            return fy_error_json(g_create_error);
        }
        created_here = 1;
    }
    pthread_mutex_unlock(&g_create);
    if (!created_here && (*g_vm)->AttachCurrentThread(g_vm, (void **)&env, NULL) != JNI_OK) {
        return fy_error_json("não foi possível anexar a thread ao runtime Java");
    }

    char *out = NULL;
    jclass cls = (*env)->FindClass(env, "freeyomi/FYHost");
    jmethodID call = cls ? (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;") : NULL;
    if (!cls || !call) {
        out = fy_exception(env, "runtime de extensões ausente");
    } else {
        jstring request = (*env)->NewStringUTF(env, job->request);
        jstring result = (jstring)(*env)->CallStaticObjectMethod(env, cls, call, request);
        if ((*env)->ExceptionCheck(env)) {
            out = fy_exception(env, "FYHost.call");
        } else if (result) {
            const char *chars = (*env)->GetStringUTFChars(env, result, NULL);
            out = strdup(chars);
            (*env)->ReleaseStringUTFChars(env, result, chars);
            (*env)->DeleteLocalRef(env, result);
        } else {
            out = fy_error_json("resposta vazia do runtime");
        }
        if (request) (*env)->DeleteLocalRef(env, request);
    }
    (*g_vm)->DetachCurrentThread(g_vm);
    return out;
}

static void *fy_thread(void *arg) {
    fy_job *job = (fy_job *)arg;
    char *out = fy_run(job);
    job->callback(job->context, out ? out : fy_error_json("sem memória"));
    free(job->classPath);
    free(job->request);
    free(job);
    return NULL;
}

void fy_jvm_call_async(const char *classPath, const char *request, void *context, fy_jvm_callback callback) {
    fy_job *job = calloc(1, sizeof *job);
    if (job) {
        job->classPath = strdup(classPath ? classPath : "");
        job->request = strdup(request ? request : "{}");
        job->context = context;
        job->callback = callback;
    }
    if (!job || !job->classPath || !job->request) {
        callback(context, fy_error_json("sem memória"));
        return;
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 32 * 1024 * 1024);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int rc = pthread_create(&thread, &attr, fy_thread, job);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        free(job->classPath); free(job->request); free(job);
        callback(context, fy_error_json("não foi possível criar a thread do runtime"));
    }
}

#endif
