package com.cx.weibo.android.data

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File

/** 一次缓存快照：页面原文列表 + 下一页游标 */
data class FeedSnapshot(
    val pages: List<String>,
    val cursor: String?,
)

/**
 * 信息流本地缓存。
 *
 * 存的是**服务端响应原文**（一页一条）+ **翻页游标** ——
 * 存原文是为了重开时用和网络请求完全相同的解析路径；
 * 存游标是因为没有它「加载更多」就断了（踩过）。
 */
object FeedCache {

    private val gson = Gson()
    private val type = object : TypeToken<FeedSnapshot>() {}.type
    private const val TAG = "WeiboResume"

    private fun file(c: Context, feed: String) = File(c.filesDir, "feed_$feed.json")

    fun load(c: Context, feed: String): FeedSnapshot? {
        val f = file(c, feed)
        if (!f.exists()) return null
        val r = runCatching { gson.fromJson<FeedSnapshot>(f.readText(), type) }
        r.exceptionOrNull()?.let {
            android.util.Log.d(TAG, "cache parse FAILED: ${it.javaClass.simpleName}: ${it.message}")
        }
        return r.getOrNull()?.takeIf { it.pages.isNotEmpty() }
    }

    fun save(c: Context, feed: String, snapshot: FeedSnapshot) {
        if (snapshot.pages.isEmpty()) return
        val r = runCatching {
            val tmp = File(c.filesDir, "feed_$feed.json.tmp")
            tmp.writeText(gson.toJson(snapshot))
            tmp.renameTo(file(c, feed))
        }
        r.exceptionOrNull()?.let {
            android.util.Log.d(TAG, "cache save FAILED: ${it.javaClass.simpleName}: ${it.message}")
        }
    }

    fun clear(c: Context, feed: String) {
        runCatching { file(c, feed).delete() }
    }
}
