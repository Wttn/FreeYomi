/*
 * FreeYomi — ponte entre o app e o runtime de extensões (protótipo).
 *
 * Este arquivo é copiado para dentro do fork do Tachidesk-Server do Tachimanga
 * (tachimanga/Tachidesk-Server, MPL-2.0) durante o build, e usa as classes
 * dele: compatibilidade Android, rede (OkHttp) e API de fontes do Tachiyomi.
 * Licença deste arquivo: MPL-2.0, como o código ao qual ele se liga.
 */
package freeyomi

import eu.kanade.tachiyomi.App
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import io.javalin.plugin.json.JavalinJackson
import io.javalin.plugin.json.JsonMapper
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.kodein.di.DI
import org.kodein.di.bind
import org.kodein.di.conf.global
import org.kodein.di.singleton
import suwayomi.tachidesk.manga.impl.util.PackageTools
import suwayomi.tachidesk.server.ApplicationDirs
import suwayomi.tachidesk.server.ServerConfig
import suwayomi.tachidesk.server.androidCompat
import xyz.nulldev.androidcompat.AndroidCompatInitializer
import xyz.nulldev.androidcompat.CommonSwitch
import xyz.nulldev.ts.config.ConfigKodeinModule
import xyz.nulldev.ts.config.GlobalConfigManager
import java.io.File
import java.util.Locale

object FYHost {
    private var ready = false

    /**
     * Argumento: "<pasta de dados>|<.jar da extensão>|<classe principal>".
     * Carrega a extensão e lista a primeira página de populares da primeira fonte.
     */
    @JvmStatic
    fun run(arg: String): String {
        val parts = arg.split("|")
        if (parts.size < 3) return "ERRO argumento inválido: $arg"
        val (root, jar, className) = parts
        val log = StringBuilder()
        return try {
            val t0 = System.currentTimeMillis()
            if (!ready) {
                init(root)
                ready = true
            }
            val t1 = System.currentTimeMillis()
            log.append("init=${t1 - t0}ms")
            val instance = PackageTools.loadExtensionSources(jar, className)
            val sources: List<Source> = when (instance) {
                is Source -> listOf(instance)
                is SourceFactory -> instance.createSources()
                else -> error("tipo de extensão desconhecido: ${instance.javaClass}")
            }
            val source = sources.filterIsInstance<CatalogueSource>().firstOrNull()
                ?: error("a extensão não tem fonte de catálogo")
            val t2 = System.currentTimeMillis()
            log.append(" | carregar=${t2 - t1}ms | fonte=${source.name} (${source.lang}) | ${sources.size} fonte(s)")
            val page = runBlocking { source.getPopularManga(1) }
            val t3 = System.currentTimeMillis()
            log.append(" | populares=${page.mangas.size} em ${t3 - t2}ms")
            page.mangas.take(3).forEach { log.append(" | «${it.title}»") }
            log.toString()
        } catch (t: Throwable) {
            log.append(" | ERRO ").append(t.stackTraceToString().take(4000))
            log.toString()
        }
    }

    private fun init(root: String) {
        System.setProperty("suwayomi.tachidesk.config.server.rootDir", root)
        System.setProperty("os.name", "Mac OS X")
        // Rede só pelo OkHttp (sem as pontes nativas do Tachimanga, que este app ainda não implementa).
        UncaughtExceptionInterceptor.ENABLE_NATIVE_NET = false
        CommonSwitch.ENABLE_NATIVE_COOKIE = false
        Locale.setDefault(Locale.ENGLISH)

        GlobalConfigManager.registerModule(ServerConfig.register(GlobalConfigManager.config))
        val dirs = ApplicationDirs()
        DI.global.addImport(
            DI.Module("FreeYomi") {
                bind<ApplicationDirs>() with singleton { dirs }
                bind<JsonMapper>() with singleton { JavalinJackson() }
                bind<Json>() with singleton { Json { ignoreUnknownKeys = true } }
            },
        )
        listOf(dirs.dataRoot, dirs.extensionsRoot, dirs.tempRoot).forEach { File(it).mkdirs() }
        DI.global.addImport(ConfigKodeinModule().create())
        AndroidCompatInitializer().init()
        androidCompat.startApp(App())
    }
}
