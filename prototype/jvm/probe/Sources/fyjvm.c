// Ponte mínima para a JVM embutida (OpenJDK Mobile, interpretador Zero, estático).
//
// A JVM roda numa thread própria com pilha grande: o Zero interpreta em C++ e
// usa bastante pilha, e a thread principal do iOS tem só 1 MB.
#include "fyjvm.h"
#include <jni.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

static JavaVM *g_vm = NULL;
static FILE *g_log = NULL;

// Toda a saída da JVM vai para $TMPDIR/fyjvm.log (o CI lê esse arquivo do
// contêiner do app no simulador, inclusive quando a JVM encerra o processo).
static void fy_open_log(void) {
    if (g_log) return;
    const char *tmp = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/fyjvm.log", tmp ? tmp : "/tmp");
    g_log = fopen(path, "w");
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

typedef struct {
    const char *classPath;
    const char *className;
    const char *argument;
    char *out;
    int outLength;
    int result;
} fy_call;

static void fy_write(fy_call *c, const char *text) {
    snprintf(c->out, (size_t)c->outLength, "%s", text ? text : "(nulo)");
}

static void fy_describe_exception(JNIEnv *env, fy_call *c, const char *where) {
    jthrowable t = (*env)->ExceptionOccurred(env);
    (*env)->ExceptionClear(env);
    char buffer[4096];
    snprintf(buffer, sizeof buffer, "%s: exceção Java sem detalhes", where);
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
    fy_write(c, buffer);
}

static void *fy_thread(void *arg) {
    fy_call *c = (fy_call *)arg;
    JNIEnv *env = NULL;
    c->result = -1;

    if (g_vm == NULL) {
        fy_open_log();
        if (g_log) { fprintf(g_log, "[fyjvm] classpath=%s\n", c->classPath); fflush(g_log); }
        char cp[8192];
        snprintf(cp, sizeof cp, "-Djava.class.path=%s", c->classPath);
        JavaVMOption options[] = {
            { .optionString = cp },
            { .optionString = "-Xshare:off" },
            { .optionString = "-XX:+UseSerialGC" },
            { .optionString = "-Xmx256m" },
            { .optionString = "-Xss4m" },
            { .optionString = "-XX:-UsePerfData" },
            { .optionString = "-Djava.awt.headless=true" },
            { .optionString = "-Xlog:class+path=info,os=info" },
            { .optionString = "vfprintf", .extraInfo = (void *)fy_vfprintf },
            { .optionString = "exit", .extraInfo = (void *)fy_exit_hook },
        };
        JavaVMInitArgs args;
        args.version = JNI_VERSION_10;
        args.nOptions = (jint)(sizeof options / sizeof options[0]);
        args.options = options;
        args.ignoreUnrecognized = JNI_TRUE;
        jint rc = JNI_CreateJavaVM(&g_vm, (void **)&env, &args);
        if (rc != JNI_OK) {
            char msg[128];
            snprintf(msg, sizeof msg, "JNI_CreateJavaVM falhou (%d)", (int)rc);
            fy_write(c, msg);
            g_vm = NULL;
            c->result = (int)rc;
            return NULL;
        }
    } else if ((*g_vm)->AttachCurrentThread(g_vm, (void **)&env, NULL) != JNI_OK) {
        fy_write(c, "AttachCurrentThread falhou");
        return NULL;
    }

    char name[512];
    snprintf(name, sizeof name, "%s", c->className);
    for (char *p = name; *p; p++) if (*p == '.') *p = '/';

    jclass cls = (*env)->FindClass(env, name);
    if (!cls) { fy_describe_exception(env, c, "FindClass"); goto done; }
    jmethodID run = (*env)->GetStaticMethodID(env, cls, "run", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!run) { fy_describe_exception(env, c, "GetStaticMethodID"); goto done; }
    jstring argument = (*env)->NewStringUTF(env, c->argument ? c->argument : "");
    jstring result = (jstring)(*env)->CallStaticObjectMethod(env, cls, run, argument);
    if ((*env)->ExceptionCheck(env)) { fy_describe_exception(env, c, "run"); goto done; }
    if (result) {
        const char *chars = (*env)->GetStringUTFChars(env, result, NULL);
        fy_write(c, chars);
        (*env)->ReleaseStringUTFChars(env, result, chars);
    } else {
        fy_write(c, "");
    }
    c->result = 0;

done:
    (*g_vm)->DetachCurrentThread(g_vm);
    return NULL;
}

int fy_jvm_run(const char *classPath, const char *className, const char *argument, char *out, int outLength) {
    fy_call call = { classPath, className, argument, out, outLength, -1 };
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 32 * 1024 * 1024);
    pthread_t thread;
    if (pthread_create(&thread, &attr, fy_thread, &call) != 0) {
        snprintf(out, (size_t)outLength, "pthread_create falhou");
        return -1;
    }
    pthread_join(thread, NULL);
    pthread_attr_destroy(&attr);
    return call.result;
}
