package com.cx.weibo.cli

import com.cx.weibo.QrStatus
import com.cx.weibo.WeiboClient
import com.cx.weibo.http.JvmHttpEngine
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption

private val DIR: Path = Path.of(System.getProperty("user.home"), ".weibo-client")
private val COOKIE: Path = DIR.resolve("cookies.tsv")

fun main(args: Array<String>) {
    val cmd = args.firstOrNull() ?: "help"
    val client = WeiboClient(JvmHttpEngine())
    try {
        when (cmd) {
            "login"     -> login(client)
            "whoami"    -> whoami(client)
            "hot"       -> hot(client)
            "timeline"  -> timeline(client, args.getOrNull(1)?.toIntOrNull() ?: 20)
            "meblog"    -> myblog(client)
            "following" -> following(client)
            "band"      -> band(client)
            "detail"    -> detail(client, args.getOrNull(1))
            "comments"  -> comments(client, args.getOrNull(1), args.getOrNull(2)?.toIntOrNull() ?: 20)
            "reposts"   -> reposts(client, args.getOrNull(1))
            "search"    -> search(client, args.drop(1).joinToString(" "), args.getOrNull(1)?.toIntOrNull())
            "user"      -> user(client, args.getOrNull(1))
            "logout"    -> { Files.deleteIfExists(COOKIE); println("已删除本地 cookie") }
            else        -> usage()
        }
    } catch (e: Exception) {
        System.err.println("✗ 错误: ${e.message}")
        kotlin.system.exitProcess(1)
    }
}

private fun usage() {
    println(
        """
        weibo-client — 微博第三方客户端（CLI）

          login              扫码登录（保存会话）
          whoami             显示当前账号
          hot                热搜榜（简）
          band               热搜榜（含标签/热度）
          timeline [n]       首页时间线（默认 20 条）
          meblog             我的微博
          user <uid>         指定用户的微博
          following          关注列表
          detail <mid>       单条微博详情
          comments <mid> [n] 评论列表（默认 20 条）
          reposts <mid>      转发列表
          search <关键词>    搜索微博
          logout             清除本地会话
        """.trimIndent()
    )
}

// ---------------- 命令实现 ----------------

private fun login(client: WeiboClient) {
    if (client.restore(COOKIE)) {
        println("✓ 已有有效会话（uid=${client.uid}），无需重新登录")
        return
    }
    Files.createDirectories(DIR)
    client.auth.prepare()
    val qr = client.auth.createQr()

    val png = DIR.resolve("qr.png")
    runCatching {
        URI.create(qr.imageUrl).toURL().openStream().use {
            Files.copy(it, png, StandardCopyOption.REPLACE_EXISTING)
        }
    }
    println("二维码已保存 → $png")
    println("（也可直接用浏览器打开该 URL 扫码）")
    println("请用手机微博 App 扫码并确认…\n")

    var lastState = ""
    val deadline = System.currentTimeMillis() + 180_000
    while (System.currentTimeMillis() < deadline) {
        val st = client.auth.poll(qr.qrid)
        if (st.state.name != lastState) {
            println("  [${st.state}] ${st.message ?: ""}")
            lastState = st.state.name
        }
        when (st.state) {
            QrStatus.State.CONFIRMED -> {
                st.url?.let { client.auth.complete(it) }
                if (client.isLoggedIn()) {
                    client.save(COOKIE)
                    if (client.restore(COOKIE)) {
                        println("\n✓ 登录成功！uid=${client.uid}")
                        return
                    }
                }
                println("✗ 已确认但未取得会话 cookie")
                return
            }
            QrStatus.State.EXPIRED, QrStatus.State.ERROR -> {
                println("✗ 登录失败（${st.state}）${st.message ?: ""}，请重试")
                return
            }
            else -> Thread.sleep(2000)
        }
    }
    println("✗ 超时未确认，请重新 login")
}

private fun whoami(client: WeiboClient) {
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val u = client.profile() ?: run { println("取资料失败"); return }
    println("uid        : ${u.idstr}")
    println("昵称       : ${u.screenName}")
    println("关注 / 粉丝 : ${u.friendsCount} / ${u.followersCount}")
    println("微博数     : ${u.statusesCount}")
    println("认证       : ${if (u.verified == true) "是" else "否"}")
    u.description?.takeIf { it.isNotBlank() }?.let { println("简介       : $it") }
}

private fun hot(client: WeiboClient) {
    client.hotSearch().take(20).forEachIndexed { i, h ->
        println("%2d. %-32s %s".format(i + 1, h.word ?: "", h.num ?: ""))
    }
}

private fun timeline(client: WeiboClient, count: Int) {
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.homeTimeline(count = count)
    println("首页时间线（${list.size} 条）\n")
    printStatuses(list)
}

private fun myblog(client: WeiboClient) {
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.myBlog()
    println("我的微博（${list.size} 条）\n")
    printStatuses(list)
}

private fun following(client: WeiboClient) {
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val users = client.following()
    println("关注（${users.size} 人）\n")
    users.forEach { u ->
        println("· ${u.screenName}  (${u.idstr})")
    }
}

private fun printStatuses(list: List<com.cx.weibo.Status>) {
    if (list.isEmpty()) { println("(空)"); return }
    list.forEach { s ->
        val name = s.user?.screenName ?: "?"
        val text = s.plainText.replace("\n", " ").take(120)
        println("─".repeat(60))
        println("$name  ·  ${s.createdAt ?: ""}   [mid=${s.idstr}]")
        println(text)
        println("  转发 ${s.repostsCount ?: 0}  评论 ${s.commentsCount ?: 0}  赞 ${s.attitudesCount ?: 0}")
    }
}

private fun band(client: WeiboClient) {
    client.hotBand(count = 50).forEach { h ->
        val tag = h.labelName ?: h.iconDesc ?: ""
        println("%2d. %-30s %-10s %s".format(h.realpos ?: h.rank ?: 0, h.word ?: "", tag, h.num ?: ""))
    }
}

private fun detail(client: WeiboClient, mid: String?) {
    if (mid == null) { println("用法: detail <mid>"); return }
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val s = client.statusDetail(mid)
    println("作者 : ${s.user?.screenName} (${s.user?.idstr})")
    println("时间 : ${s.createdAt}")
    println("来源 : ${s.source ?: ""}")
    println("mid  : ${s.idstr}")
    println("─".repeat(60))
    println(s.plainText)
    println("─".repeat(60))
    println("转发 ${s.repostsCount ?: 0}  评论 ${s.commentsCount ?: 0}  赞 ${s.attitudesCount ?: 0}")
}

private fun comments(client: WeiboClient, mid: String?, count: Int) {
    if (mid == null) { println("用法: comments <mid> [n]"); return }
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.comments(mid, count = count)
    println("评论（${list.size} 条）\n")
    list.forEach { c ->
        val who = c.user?.screenName ?: "?"
        val mark = if (c.isAuthor == true) " [作者]" else ""
        val text = c.plainText.replace("\n", " ").take(100)
        println("· $who$mark: $text  （赞 ${c.likeCounts ?: 0}）")
    }
}

private fun reposts(client: WeiboClient, mid: String?) {
    if (mid == null) { println("用法: reposts <mid>"); return }
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.reposts(mid)
    println("转发（${list.size} 条）\n")
    printStatuses(list)
}

private fun search(client: WeiboClient, q: String, page: Int?) {
    if (q.isBlank()) { println("用法: search <关键词>"); return }
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.search(q, page = page ?: 1)
    println("搜索「$q」（${list.size} 条）\n")
    printStatuses(list)
}

private fun user(client: WeiboClient, uid: String?) {
    if (uid == null) { println("用法: user <uid>"); return }
    if (!client.restore(COOKIE)) { println("未登录，请先 login"); return }
    val list = client.myBlog(uid = uid)
    println("用户 $uid 的微博（${list.size} 条）\n")
    printStatuses(list)
}
