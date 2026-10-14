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
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import io.javalin.plugin.json.JavalinJackson
import io.javalin.plugin.json.JsonMapper
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
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
import java.util.concurrent.ConcurrentHashMap

object FYHost {
    @Volatile private var ready = false
    private val lock = Any()

    /** Fontes carregadas, por id (o mesmo id Long do Tachiyomi, em texto). */
    private val sources = ConcurrentHashMap<String, CatalogueSource>()

    /**
     * API usada pelo app: recebe um pedido JSON e devolve uma resposta JSON.
     *
     * Pedido: {"op": "...", ...}. Resposta: {"ok": true, "result": ...} ou
     * {"ok": false, "error": "..."}. Operações:
     *  - init {root}
     *  - load {jar, className}            -> {sources: [fonte]}
     *  - popular/latest {source, page}    -> {mangas: [mangá], hasNextPage}
     *  - search {source, page, query}     -> idem
     *  - details {source, manga}          -> mangá
     *  - chapters {source, manga}         -> [capítulo]
     *  - pages {source, chapter}          -> [{index, url, imageUrl}]
     */
    @JvmStatic
    fun call(request: String): String {
        if (Thread.currentThread().contextClassLoader == null) {
            Thread.currentThread().contextClassLoader = FYHost::class.java.classLoader
        }
        return try {
            val req = Json.parseToJsonElement(request).jsonObject
            val result = handle(req)
            buildJsonObject {
                put("ok", true)
                put("result", result)
            }.toString()
        } catch (t: Throwable) {
            val root = generateSequence(t) { it.cause }.last()
            // Sem mensagem (ex.: NullPointerException), indica onde aconteceu.
            val message = root.message?.takeIf { it.isNotBlank() }
                ?: "${root.javaClass.simpleName} em ${root.stackTrace.take(2).joinToString(" ← ")}"
            buildJsonObject {
                put("ok", false)
                put("error", message.take(1000))
                put("type", root.javaClass.name)
                put("trace", t.stackTraceToString().take(3000))
            }.toString()
        }
    }

    private fun JsonObject.str(key: String): String =
        this[key]?.jsonPrimitive?.contentOrNull ?: error("campo ausente: $key")

    private fun JsonObject.int(key: String, default: Int): Int = this[key]?.jsonPrimitive?.intOrNull ?: default

    private fun source(req: JsonObject): CatalogueSource {
        val id = req.str("source")
        return sources[id] ?: error("fonte $id não carregada")
    }

    private fun handle(req: JsonObject): JsonElement {
        when (val op = req.str("op")) {
            "init" -> {
                ensureInit(req.str("root"))
                return JsonPrimitive(true)
            }
            "load" -> {
                check(ready) { "runtime não iniciado" }
                return load(req.str("jar"), req.str("className"))
            }
            "popular" -> return page(runBlocking { source(req).getPopularManga(req.int("page", 1)) })
            "latest" -> return page(runBlocking { source(req).getLatestUpdates(req.int("page", 1)) })
            "search" -> {
                val s = source(req)
                return page(runBlocking { s.getSearchManga(req.int("page", 1), req.str("query"), s.getFilterList()) })
            }
            "details" -> {
                val s = source(req)
                val manga = mangaFrom(req["manga"]!!.jsonObject)
                val update = runBlocking { s.getMangaUpdate(manga, emptyList(), true, false) }
                val result = update.manga
                if (result.url.isEmpty()) result.url = manga.url
                if (result.title.isEmpty()) result.title = manga.title
                return mangaJson(result)
            }
            "chapters" -> {
                val s = source(req)
                val manga = mangaFrom(req["manga"]!!.jsonObject)
                val update = runBlocking { s.getMangaUpdate(manga, emptyList(), false, true) }
                return buildJsonArray { update.chapters.forEach { add(chapterJson(it)) } }
            }
            "pages" -> {
                val s = source(req)
                val c = req["chapter"]!!.jsonObject
                val chapter = SChapter.create().apply {
                    url = c.str("url")
                    name = c["name"]?.jsonPrimitive?.contentOrNull ?: ""
                    scanlator = c["scanlator"]?.jsonPrimitive?.contentOrNull
                    chapter_number = c["number"]?.jsonPrimitive?.contentOrNull?.toFloatOrNull() ?: -1f
                    date_upload = c["dateUpload"]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
                    (c["memo"] as? JsonObject)?.let { memo = it }
                }
                val pages = runBlocking { s.getPageList(chapter) }
                return buildJsonArray {
                    for (p in pages) {
                        var image = p.imageUrl?.trim()
                        if (image.isNullOrEmpty() && s is HttpSource && p.url.isNotEmpty()) {
                            image = runBlocking { s.getImageUrl(p) }.trim()
                        }
                        // Mesma normalização do Tachidesk (ChapterUtil.preprocessPageList).
                        if (image != null && image.startsWith("://")) image = "https$image"
                        if (image != null && image.startsWith("//")) image = "https:$image"
                        add(
                            buildJsonObject {
                                put("index", p.index)
                                put("url", p.url)
                                put("imageUrl", image ?: "")
                            },
                        )
                    }
                }
            }
            else -> error("operação desconhecida: $op")
        }
    }

    private fun ensureInit(root: String) {
        if (ready) return
        synchronized(lock) {
            if (!ready) {
                init(root)
                ready = true
            }
        }
    }

    private fun load(jar: String, className: String): JsonElement {
        val instance = PackageTools.loadExtensionSources(jar, className)
        val list: List<Source> = when (instance) {
            is Source -> listOf(instance)
            is SourceFactory -> instance.createSources()
            else -> error("tipo de extensão desconhecido: ${instance.javaClass.name}")
        }
        val catalogue = list.filterIsInstance<CatalogueSource>()
        if (catalogue.isEmpty()) error("a extensão não tem fontes de catálogo")
        return buildJsonObject {
            put(
                "sources",
                buildJsonArray {
                    for (s in catalogue) {
                        sources[s.id.toString()] = s
                        add(
                            buildJsonObject {
                                put("id", s.id.toString())
                                put("name", s.name)
                                put("lang", s.lang)
                                put("supportsLatest", s.supportsLatest)
                                val http = s as? HttpSource
                                put("baseUrl", http?.baseUrl ?: "")
                                put(
                                    "headers",
                                    buildJsonObject {
                                        http?.let { h -> h.headers.names().forEach { name -> put(name, h.headers[name] ?: "") } }
                                    },
                                )
                            },
                        )
                    }
                },
            )
        }
    }

    private fun page(p: MangasPage): JsonElement = buildJsonObject {
        put("mangas", buildJsonArray { p.mangas.forEach { add(mangaJson(it)) } })
        put("hasNextPage", p.hasNextPage)
    }

    private fun mangaJson(m: SManga): JsonElement = buildJsonObject {
        put("url", m.url)
        put("title", m.title)
        put("thumbnailUrl", m.thumbnail_url)
        put("author", m.author)
        put("artist", m.artist)
        put("description", m.description)
        put("genre", m.genre)
        put("status", m.status)
        put("initialized", m.initialized)
        // Metadados da extensão (extensions-lib 1.6): o app guarda e devolve sem interpretar.
        if (m.memo.isNotEmpty()) put("memo", m.memo)
    }

    private fun mangaFrom(o: JsonObject): SManga = SManga.create().apply {
        url = o.str("url")
        title = o["title"]?.jsonPrimitive?.contentOrNull ?: ""
        thumbnail_url = o["thumbnailUrl"]?.jsonPrimitive?.contentOrNull
        author = o["author"]?.jsonPrimitive?.contentOrNull
        artist = o["artist"]?.jsonPrimitive?.contentOrNull
        description = o["description"]?.jsonPrimitive?.contentOrNull
        genre = o["genre"]?.jsonPrimitive?.contentOrNull
        status = o["status"]?.jsonPrimitive?.intOrNull ?: 0
        (o["memo"] as? JsonObject)?.let { memo = it }
    }

    private fun chapterJson(c: SChapter): JsonElement = buildJsonObject {
        put("url", c.url)
        put("name", c.name)
        put("number", c.chapter_number.toDouble())
        put("scanlator", c.scanlator)
        put("dateUpload", c.date_upload)
        if (c.memo.isNotEmpty()) put("memo", c.memo)
    }

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
        // Threads anexadas pelo JNI não têm class loader de contexto (o Typesafe Config precisa).
        if (Thread.currentThread().contextClassLoader == null) {
            Thread.currentThread().contextClassLoader = FYHost::class.java.classLoader
        }
        return try {
            val t0 = System.currentTimeMillis()
            ensureInit(root)
            val t1 = System.currentTimeMillis()
            log.append("init=${t1 - t0}ms")
            val instance = PackageTools.loadExtensionSources(jar, className)
            val loaded: List<Source> = when (instance) {
                is Source -> listOf(instance)
                is SourceFactory -> instance.createSources()
                else -> error("tipo de extensão desconhecido: ${instance.javaClass}")
            }
            val source = loaded.filterIsInstance<CatalogueSource>().firstOrNull()
                ?: error("a extensão não tem fonte de catálogo")
            val t2 = System.currentTimeMillis()
            log.append(" | carregar=${t2 - t1}ms | fonte=${source.name} (${source.lang}) | ${loaded.size} fonte(s)")
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
