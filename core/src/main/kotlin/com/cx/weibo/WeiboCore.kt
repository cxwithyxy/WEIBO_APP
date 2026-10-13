package com.cx.weibo

import com.cx.weibo.http.HttpEngine
import com.cx.weibo.http.RawRequest
import com.cx.weibo.http.RawResponse
import com.google.gson.Gson
import com.google.gson.annotations.SerializedName
import java.net.URI
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path

const val DESKTOP_UA =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

const val HOST_WEIBO = "https://weibo.com"
const val HOST_PASSPORT = "https://passport.weibo.com"

/** 微博返回 ok!=1 时抛出；message 为服务端文案。 */
class WeiboException(message: String) : RuntimeException(message)

// ------------------------------------------------------------------
// 数据模型
// ------------------------------------------------------------------

data class User(
    @SerializedName("idstr") val idstr: String? = null,
    @SerializedName("screen_name") val screenName: String? = null,
    @SerializedName("profile_image_url") val avatar: String? = null,
    @SerializedName("followers_count") val followersCount: Long? = null,
    @SerializedName("friends_count") val friendsCount: Long? = null,
    @SerializedName("statuses_count") val statusesCount: Long? = null,
    val description: String? = null,
    val verified: Boolean? = null,
    val location: String? = null,
)

data class Status(
    @SerializedName("idstr") val idstr: String? = null,
    @SerializedName("created_at") val createdAt: String? = null,
    @SerializedName("text_raw") val textRaw: String? = null,
    val text: String? = null,
    @SerializedName("reposts_count") val repostsCount: Int? = null,
    @SerializedName("comments_count") val commentsCount: Int? = null,
    @SerializedName("attitudes_count") val attitudesCount: Int? = null,
    val source: String? = null,
    val user: User? = null,
) {
    /** 纯文本（优先 text_raw，其次剥离 HTML 标签） */
    val plainText: String
        get() = textRaw ?: text?.replace(Regex("<[^>]+>"), "") ?: ""
}

data class HotItem(
    val word: String? = null,
    val num: Long? = null,
    @SerializedName("realpos") val realpos: Int? = null,
    val label: String? = null,
)

/** 评论 */
data class Comment(
    @SerializedName("idstr") val idstr: String? = null,
    @SerializedName("created_at") val createdAt: String? = null,
    @SerializedName("text_raw") val textRaw: String? = null,
    val text: String? = null,
    @SerializedName("like_counts") val likeCounts: Int? = null,
    @SerializedName("floor_number") val floorNumber: Int? = null,
    @SerializedName("is_mblog_author") val isAuthor: Boolean? = null,
    val user: User? = null,
    @SerializedName("reply_comment") val replyComment: Comment? = null,
) {
    val plainText: String
        get() = textRaw ?: text?.replace(Regex("<[^>]+>"), "") ?: ""
}

/** 热搜榜条目（hot_band） */
data class HotBandItem(
    val word: String? = null,
    val note: String? = null,
    val num: Long? = null,
    val rank: Int? = null,
    @SerializedName("realpos") val realpos: Int? = null,
    @SerializedName("label_name") val labelName: String? = null,
    @SerializedName("icon_desc") val iconDesc: String? = null,
)

// ------------------------------------------------------------------
// 响应信封
// ------------------------------------------------------------------

internal data class Envelope(val ok: Int? = null, val message: String? = null)

internal data class TimelineResp(
    val ok: Int? = null,
    val message: String? = null,
    val statuses: List<Status>? = null,
    @SerializedName("since_id") val sinceId: String? = null,
    @SerializedName("max_id") val maxId: String? = null,
)

internal data class MyBlogResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: MyBlogData? = null,
)

internal data class MyBlogData(
    val list: List<Status>? = null,
    @SerializedName("since_id") val sinceId: String? = null,
)

internal data class ProfileInfoResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: ProfileInfoData? = null,
)

internal data class ProfileInfoData(val user: User? = null)

internal data class HotResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: HotData? = null,
)

internal data class HotData(val realtime: List<HotItem>? = null)

internal data class FollowResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: FollowData? = null,
)

internal data class FollowData(
    val follows: FollowUsers? = null,
    @SerializedName("total_number") val totalNumber: Int? = null,
)

internal data class FollowUsers(val users: List<User>? = null)

internal data class SearchResp(
    val ok: Int? = null,
    val message: String? = null,
    val statuses: List<Status>? = null,
    @SerializedName("total_number") val totalNumber: Int? = null,
)

internal data class CommentsResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: List<Comment>? = null,
    @SerializedName("total_number") val totalNumber: Int? = null,
    @SerializedName("max_id") val maxId: Long? = null,
)

internal data class RepostResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: List<Status>? = null,
    @SerializedName("total_number") val totalNumber: Int? = null,
    @SerializedName("max_page") val maxPage: Int? = null,
)

internal data class HotBandResp(
    val ok: Int? = null,
    val message: String? = null,
    val data: HotBandData? = null,
)

internal data class HotBandData(@SerializedName("band_list") val bandList: List<HotBandItem>? = null)

// ------------------------------------------------------------------
// HTTP（自管 cookie + 自跟随重定向）
//
// 为什么不用 JDK 的 CookieManager：
//   1) 外部注入的 cookie 它不会发出去（实测导致 403/重定向登录页）
//   2) 自动跟随重定向时，中间跳转的 Set-Cookie 会被丢弃
// 而微博登录恰恰依赖跨跳转的 Set-Cookie，所以必须自己接管。
// ------------------------------------------------------------------

class WeiboHttp(
    private val engine: HttpEngine,
    val ua: String = DESKTOP_UA,
) {

    val gson: Gson = Gson()

    private val values = LinkedHashMap<String, String>()   // name -> value
    private val domains = HashMap<String, String>()        // name -> domain

    // ---------------- cookie ----------------

    private fun cookieHeader(host: String): String =
        values.entries
            .filter { (name, _) ->
                val d = (domains[name] ?: host).removePrefix(".")
                host == d || host.endsWith(".$d")
            }
            .joinToString("; ") { "${it.key}=${it.value}" }

    private fun absorb(host: String, resp: RawResponse) {
        resp.headerValues("Set-Cookie").forEach { raw ->
            val seg = raw.split(";")
            val kv = seg[0].trim()
            val i = kv.indexOf('=')
            if (i <= 0) return@forEach
            val name = kv.substring(0, i).trim()
            val value = kv.substring(i + 1).trim()
            val dom = seg.drop(1)
                .map { it.trim() }
                .firstOrNull { it.startsWith("domain=", ignoreCase = true) }
                ?.substringAfter('=')?.trim()
                ?: host
            values[name] = value
            domains[name] = dom
        }
    }

    private class Res(
        val status: Int,
        val location: String?,
        val body: String,
    )

    private fun raw(url: String, method: String, body: String?, referer: String?, ajax: Boolean): Res {
        val uri = URI.create(url)
        val headers = buildMap {
            put("User-Agent", ua)
            put("Accept-Language", "zh-CN,zh;q=0.9")
            put(
                "Accept",
                if (ajax) "application/json, text/plain, */*"
                else "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            )
            cookieHeader(uri.host).takeIf { it.isNotEmpty() }?.let { put("Cookie", it) }
            referer?.let { put("Referer", it) }
            if (ajax) put("X-Requested-With", "XMLHttpRequest")
            if (body != null) put("Content-Type", "application/x-www-form-urlencoded")
        }
        val resp = engine.execute(
            RawRequest(url, method, headers, body?.toByteArray(StandardCharsets.UTF_8))
        )
        absorb(uri.host, resp)
        return Res(resp.status, resp.header("Location"), resp.bodyText)
    }

    /** GET，自动跟随最多 10 跳重定向，每跳都吸收 Set-Cookie */
    fun get(url: String, referer: String? = null, ajax: Boolean = false): String {
        var current = url
        var hops = 0
        while (true) {
            val res = raw(current, "GET", null, referer, ajax)
            val loc = res.location
            if (loc != null && res.status in 300..399 && hops < 10) {
                current = URI.create(current).resolve(loc).toString()
                hops++
                continue
            }
            return res.body
        }
    }

    /** POST 表单（同样跟随重定向） */
    fun postForm(url: String, form: Map<String, String>, referer: String? = null, ajax: Boolean = false): String {
        val payload = form.entries.joinToString("&") { enc(it.key) + "=" + enc(it.value) }
        var current = url
        var hops = 0
        var body: String? = payload
        while (true) {
            val res = raw(current, "POST", body, referer, ajax)
            val loc = res.location
            if (loc != null && res.status in 300..399 && hops < 10) {
                current = URI.create(current).resolve(loc).toString()
                hops++
                body = null
                continue
            }
            return res.body
        }
    }

    // ---------------- 会话状态 ----------------

    fun cookieValue(name: String): String? = values[name]

    fun cookieHeaderString(): String = values.entries.joinToString("; ") { "${it.key}=${it.value}" }

    fun isLoggedIn(): Boolean = !values["SUB"].isNullOrEmpty()

    /** 保存 cookie（TSV：domain \t path \t name \t value） */
    fun saveCookies(path: Path) {
        val lines = values.entries.map { (n, v) -> listOf(domains[n] ?: "", "/", n, v).joinToString("\t") }
        path.parent?.let { Files.createDirectories(it) }
        Files.write(path, lines)
    }

    /** 从文件恢复 cookie（兼容 Netscape 与 TSV 两种格式） */
    fun loadCookies(path: Path) {
        if (!Files.exists(path)) return
        Files.readAllLines(path).forEach { line0 ->
            var line = line0.trim()
            if (line.isEmpty()) return@forEach
            if (line.startsWith("#HttpOnly_")) line = line.removePrefix("#HttpOnly_")
            else if (line.startsWith("#")) return@forEach
            val p = line.split("\t")
            if (p.size >= 7) {                 // Netscape 格式
                values[p[5]] = p[6]; domains[p[5]] = p[0]
            } else if (p.size >= 4) {          // 本库 TSV 格式
                values[p[2]] = p[3]; domains[p[2]] = p[0]
            }
        }
    }

    internal fun enc(s: String): String = URLEncoder.encode(s, StandardCharsets.UTF_8)
}

private fun enc(s: String): String = URLEncoder.encode(s, StandardCharsets.UTF_8)
