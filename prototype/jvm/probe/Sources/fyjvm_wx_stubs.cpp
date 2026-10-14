// Símbolos de W^X (MAP_JIT) do HotSpot para macOS/AArch64.
//
// O código comum do HotSpot os referencia quando MACOS_AARCH64 está definido,
// mas no iOS com o interpretador Zero o arquivo que os define
// (os_cpu/bsd_aarch64) não é compilado. Como o Zero nunca gera código
// executável, não há página W^X para alternar: os stubs são vazios e
// _jit_exec_enabled fica sempre falso.
enum WXMode { WXWrite = 0, WXExec = 1, WXArmedForWrite = 2 };
WXMode DefaultWXWriteMode = WXExec;

class os {
public:
    static void thread_wx_enable_write_impl();
    static __thread bool _jit_exec_enabled;
};

__thread bool os::_jit_exec_enabled = false;

void os::thread_wx_enable_write_impl() {}
