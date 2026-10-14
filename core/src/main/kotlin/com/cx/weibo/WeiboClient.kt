package com.cx.weibo

import com.cx.weibo.http.HttpEngine
import java.nio.file.Path

/**
 * 微博客户端门面。
 *
 * 用法：
 * ```
 * val client = WeiboClient()
 * if (!client.restore(cookieFile)) { client.auth.loginBlocking { ... } }
 * println(client.homeTimeline())
 * ```
 *
 * 设计说明：接口层全部集中在此，微博前端一改只动这里（隔离变更风险）。
 */
class WeiboClient(engine: HttpEngine) {

    val http: WeiboHttp = WeiboHttp(engine)

    val auth = WeiboAuth(http)

    var uid: String? = null
        private set

    fun isLoggedIn(): Boolean = http.isLoggedIn()

    // 微博 /ajax/* 强制校验 Referer，缺失会 403 {"error":"Forbidden"}
    private fun referer(): String = uid?.let { "$HOST_WEIBO/u/$it" } ?: "$HOST_WEIBO/"

    /** 从 cookie 文件恢复会话；成功则填充 uid */
    fun restore(cookieFile: Path): Boolean {
        http.loadCookies(cookieFile)
        if (!http.isLoggedIn()) return false
        uid = fetchUid()
        return uid != null
    }

    fun save(cookieFile: Path) = http.saveCookies(cookieFile)

    /** 从首页 HTML 里解析自己的 uid */
    fun fetchUid(): String? {
        val html = http.get("$HOST_WEIBO/")
        return Regex("\"uid\":(\\d+)").find(html)?.groupValues?.get(1)
    }

    private fun getJson(path: String): String =
        http.get("$HOST_WEIBO$path", referer = referer(), ajax = true)

    private fun checkOk(ok: Int?, message: String?, ctx: String) {
        if (ok != 1) {
            val hint = if (ok == null) "（响应无 ok 字段，通常是被拦截或未登录）" else ""
            throw WeiboException("$ctx 失败: ok=$ok message=${message ?: ""}$hint")
        }
    }

    // ---------------- 接口 ----------------

    /**
     * 首页时间线一页。
     *
     * 翻页语义（实测）：`since_id` = 「给我比这个游标更旧的」；
     * 把服务端返回的 `nextCursor`（即响应里的 max_id_str）传回 `sinceId` 即可续拉。
     */
    fun homeTimelinePage(sinceId: String = "0", count: Int = 20): TimelinePage =
        homeTimelinePageRaw(sinceId, count).let { TimelinePage(it.statuses, it.nextCursor) }

    /** 同 homeTimelinePage，但同时返回**原始响应文本**（用于本地缓存） */
    fun homeTimelinePageRaw(sinceId: String = "0", count: Int = 20): TimelineRaw {
        val raw = getJson("/ajax/feed/unreadfriendstimeline?since_id=$sinceId&refresh=1&count=$count")
        val r = http.gson.fromJson(raw, TimelineResp::class.java)
        checkOk(r?.ok, r?.message, "首页时间线")
        return TimelineRaw(raw, r?.statuses ?: emptyList(), r?.maxIdStr ?: r?.maxId)
    }

    /** 把缓存下来的响应原文重新解析成微博列表（与网络路径**同一套解析**） */
    fun parseTimelineRaw(raw: String): List<Status> =
        runCatching { http.gson.fromJson(raw, TimelineResp::class.java)?.statuses }.getOrNull()
            ?: emptyList()

    /**
     * 某个用户的微博列表（点头像进入）。
     * `/ajax/statuses/mymblog?uid=X&page=N` —— 实测 `page=N` 翻页零重叠。
     */
    fun userTimelinePageRaw(uid: String, page: Int = 1): TimelineRaw {
        val raw = getJson("/ajax/statuses/mymblog?uid=$uid&page=$page&feature=0")
        val r = http.gson.fromJson(raw, MyBlogResp::class.java)
        checkOk(r?.ok, r?.message, "用户微博")
        return TimelineRaw(
            raw = raw,
            statuses = r?.data?.list ?: emptyList(),
            nextCursor = (page + 1).toString(),
        )
    }

    /** 用户资料（用于用户页头部展示） */
    fun userInfo(uid: String): User? = profile(uid)

    /**
     * 取长文全文。
     * 微博会把长文截断（`isLongText=true`，`text_raw` 只有百来字），
     * 全文要单独调这个接口。
     */
    fun longText(id: String): String? {
        val raw = getJson("/ajax/statuses/longtext?id=$id")
        val r = http.gson.fromJson(raw, LongTextResp::class.java)
        checkOk(r?.ok, null, "长文")
        val d = r?.data ?: return null
        val t = d.longTextContentRaw?.takeIf { it.isNotBlank() } ?: d.longTextContent ?: return null
        return t.replace(TAG_RE, "").trim().takeIf { it.isNotEmpty() }
    }

    private companion object {
        val TAG_RE = Regex("<[^>]+>")
    }

    // ==================== 互动（写操作） ====================

    private fun mutation(path: String, form: Map<String, String>, referer: String): String {
        http.ensureXsrf()
        return http.postForm("$HOST_WEIBO$path", form, referer = referer, ajax = true)
    }

    /** 写操作统一校验：ok 存在且非 1 才算失败（部分接口不返回 ok） */
    private fun checkMutation(raw: String, what: String) {
        val obj = runCatching { http.gson.fromJson(raw, com.google.gson.JsonObject::class.java) }
            .getOrNull() ?: throw WeiboException("$what 失败：响应无法解析（${raw.take(120)}）")
        val ok = obj.get("ok")?.let { runCatching { it.asInt }.getOrNull() }
        if (ok != null && ok != 1) {
            val msg = obj.get("msg")?.asString ?: obj.get("message")?.asString ?: ""
            throw WeiboException("$what 失败: ok=$ok $msg")
        }
    }

    /** 点赞。`id` 用微博的 idstr/mid。 */
    fun setLike(id: String) {
        val r = mutation("/ajax/statuses/setLike", linkedMapOf("id" to id), "https://weibo.com/detail/$id")
        checkMutation(r, "点赞")
    }

    /** 取消赞 */
    fun cancelLike(id: String) {
        val r = mutation("/ajax/statuses/cancelLike", linkedMapOf("id" to id), "https://weibo.com/detail/$id")
        checkMutation(r, "取消赞")
    }

    /** 转发。`text` 为空时用默认文案；`alsoComment` 表示同时评论。 */
    fun repost(id: String, text: String = "", alsoComment: Boolean = false, picId: String = "") {
        val r = mutation(
            "/ajax/statuses/repost",
            linkedMapOf(
                "id" to id,
                "comment" to text.trim().ifBlank { "转发微博" },
                "is_comment" to if (alsoComment) "1" else "0",
                "pic_id" to picId,
            ),
            "https://weibo.com/detail/$id",
        )
        checkMutation(r, "转发")
    }

    /** 发评论；`replyToCid` 非空时为回复某条评论。 */
    fun comment(id: String, text: String, replyToCid: String? = null, alsoRepost: Boolean = false, picId: String = "") {
        val form = linkedMapOf(
            "id" to id,
            "comment" to text,
            "pic_id" to picId,
            "is_repost" to if (alsoRepost) "1" else "0",
            "comment_ori" to "0",
            "is_comment" to "0",
            "fp" to "",
        )
        val path = if (!replyToCid.isNullOrBlank()) {
            form["cid"] = replyToCid
            "/ajax/comments/reply"
        } else {
            "/ajax/comments/create"
        }
        checkMutation(mutation(path, form, "https://weibo.com/detail/$id"), "评论")
    }

    /** 收藏 / 取消收藏 */
    fun favorite(id: String, on: Boolean = true) {
        val path = if (on) "/ajax/statuses/createFavorites" else "/ajax/statuses/destoryFavorites"
        checkMutation(
            mutation(path, linkedMapOf("id" to id), "https://weibo.com/fav"),
            if (on) "收藏" else "取消收藏",
        )
    }

    /** 删除自己发的微博 */
    fun destroyStatus(id: String) {
        checkMutation(mutation("/ajax/statuses/destroy", linkedMapOf("id" to id), "https://weibo.com/detail/$id"), "删除微博")
    }

    /**
     * 发微博（纯文字）。返回新微博的 idstr。
     *
     * 走 **weibo.com 桌面端**接口，复用现有会话 + CSRF；
     * （移动端 m.weibo.cn 是另一个域，不认 weibo.com 的 cookie，需单独登录，已避开）
     * `visible`: 0=公开 1=仅关注 6=仅自己
     */
    fun postStatus(content: String, visible: Int = 0): String {
        val text = content.trim()
        require(text.isNotEmpty()) { "微博内容不能为空" }
        val raw = mutation(
            "/ajax/statuses/update",
            linkedMapOf("content" to text, "visible" to visible.toString()),
            "https://weibo.com/",
        )
        val obj = runCatching { http.gson.fromJson(raw, com.google.gson.JsonObject::class.java) }
            .getOrNull() ?: throw WeiboException("发微博失败：响应无法解析（${raw.take(120)}）")
        val data = obj.getAsJsonObject("data")
        val ok = obj.get("ok")?.let { runCatching { it.asInt }.getOrNull() }
        if (data == null || (ok != null && ok != 1)) {
            val msg = obj.get("msg")?.asString ?: obj.get("message")?.asString ?: raw.take(120)
            throw WeiboException("发微博失败: ok=$ok $msg")
        }
        return data.get("idstr")?.asString ?: data.get("id")?.asString ?: ""
    }

    /** 首页时间线（关注的人）—— 只要第一页时用这个 */
    fun homeTimeline(count: Int = 20, sinceId: String = "0"): List<Status> =
        homeTimelinePage(sinceId, count).statuses

    /**
     * 「我的关注」时间线（纯关注，按时间倒序，无推荐/广告）。
     *
     * ⚠️ 实测：这个端点的 `since_id` **翻页无效**（第二页与第一页 100% 重叠），
     * 必须用 `page=N` 翻页（实测零重叠）。所以这里的游标是「下一页页码」。
     */
    fun followingTimelinePageRaw(page: Int = 1, count: Int = 25): TimelineRaw {
        val raw = getJson("/ajax/feed/friendstimeline?page=$page&count=$count")
        val r = http.gson.fromJson(raw, TimelineResp::class.java)
        checkOk(r?.ok, r?.message, "关注时间线")
        return TimelineRaw(
            raw = raw,
            statuses = r?.statuses ?: emptyList(),
            nextCursor = (page + 1).toString(),
        )
    }

    /** 只要第一页时用这个 */
    fun followingTimeline(count: Int = 25): List<Status> =
        followingTimelinePageRaw(1, count).statuses

    /** 某个用户的微博列表（默认自己） */
    fun myBlog(uid: String? = null, page: Int = 1): List<Status> {
        val u = uid ?: this.uid ?: throw WeiboException("未知 uid，请先 login/whoami")
        val json = getJson("/ajax/statuses/mymblog?uid=$u&page=$page&feature=0")
        val r = http.gson.fromJson(json, MyBlogResp::class.java)
        checkOk(r?.ok, r?.message, "微博列表")
        return r?.data?.list ?: emptyList()
    }

    /** 用户资料 */
    fun profile(uid: String = this.uid ?: ""): User? {
        require(uid.isNotEmpty()) { "需要 uid" }
        val json = getJson("/ajax/profile/info?uid=$uid")
        val r = http.gson.fromJson(json, ProfileInfoResp::class.java)
        checkOk(r?.ok, r?.message, "用户资料")
        return r?.data?.user
    }

    /** 关注列表 */
    fun following(uid: String = this.uid ?: ""): List<User> {
        require(uid.isNotEmpty()) { "需要 uid" }
        val json = getJson("/ajax/profile/followContent?uid=$uid")
        val r = http.gson.fromJson(json, FollowResp::class.java)
        checkOk(r?.ok, r?.message, "关注列表")
        return r?.data?.follows?.users ?: emptyList()
    }

    /** 热搜榜（公开接口，不需要登录） */
    fun hotSearch(): List<HotItem> {
        val json = getJson("/ajax/side/hotSearch")
        val r = http.gson.fromJson(json, HotResp::class.java)
        checkOk(r?.ok, r?.message, "热搜")
        return r?.data?.realtime ?: emptyList()
    }

    /** 热搜榜单详情（含 word/note/num/label） */
    fun hotBand(bandId: Int = 1, count: Int = 50): List<HotBandItem> {
        val json = getJson("/ajax/statuses/hot_band?band_id=$bandId&count=$count")
        val r = http.gson.fromJson(json, HotBandResp::class.java)
        checkOk(r?.ok, r?.message, "热搜榜单")
        return r?.data?.bandList ?: emptyList()
    }

    /**
     * 单条微博详情。
     * 注意：`statuses/show` 直接返回微博对象（无 `ok` 信封）。
     */
    fun statusDetail(mid: String): Status {
        val json = getJson("/ajax/statuses/show?id=$mid")
        return http.gson.fromJson(json, Status::class.java)
    }

    /**
     * 评论列表。
     *
     * ⚠️ 实测行为：
     *  - `count` 参数被忽略，服务端固定返回 20 条
     *  - `flow=0`（按热度）翻页**不可用**（传回 max_id 拿不到第二页）
     *  - `flow=1`（按时间）翻页正常
     *  ➡️ 需要完整评论列表时请用 `flow = 1`
     *
     * @param maxId 翻页游标（用上次响应的 max_id，首次传 0）
     * @param flow  0=按热度（首页可用，翻页无效），1=按时间（可翻页）
     */
    fun comments(mid: String, count: Int = 20, maxId: Long = 0, flow: Int = 0): List<Comment> =
        commentsPage(mid, count, maxId, flow).comments

    /** 评论一页（带下一页游标）—— 推荐用 `flow = 1` 以便翻页 */
    fun commentsPage(mid: String, count: Int = 20, maxId: Long = 0, flow: Int = 1): CommentPage {
        val json = getJson(
            "/ajax/statuses/buildComments?is_reload=1&id=$mid&is_show_bulletin=2" +
                "&is_mix=0&count=$count&max_id=$maxId&flow=$flow"
        )
        val r = http.gson.fromJson(json, CommentsResp::class.java)
        checkOk(r?.ok, r?.message, "评论")
        return CommentPage(
            comments = r?.data ?: emptyList(),
            nextMaxId = r?.maxId,
            totalNumber = r?.totalNumber,
        )
    }

    /** 转发列表 */
    fun reposts(mid: String, page: Int = 1): List<Status> {
        val json = getJson("/ajax/statuses/repostTimeline?id=$mid&page=$page")
        val r = http.gson.fromJson(json, RepostResp::class.java)
        checkOk(r?.ok, r?.message, "转发列表")
        return r?.data ?: emptyList()
    }

    /**
     * 搜索微博。
     * @param q 关键词
     * @param page 页码（从 1 开始）
     */
    fun search(q: String, count: Int = 20, page: Int = 1): List<Status> {
        val json = getJson("/ajax/statuses/search?q=${http.enc(q)}&count=$count&page=$page")
        val r = http.gson.fromJson(json, SearchResp::class.java)
        checkOk(r?.ok, r?.message, "搜索")
        return r?.statuses ?: emptyList()
    }
}
