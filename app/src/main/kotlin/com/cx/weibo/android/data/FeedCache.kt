package com.cx.weibo.android.data

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File

/**
 * 信息流本地缓存。
 *
 * 存的是**服务端响应原文**（一页一条），不是解析后的对象 ——
 * 这样重开时用的是和网络请求**完全相同**的解析路径，
 * 不会因为模型的序列化细节（懒加载属性等）出问题。
 *
 * 为什么需要缓存：推荐流的 `since_id` 翻页**本身不可靠**（实测大量重叠），
 * 光靠「翻页往回找到上次那条」找不到，必须把列表本身留下来。
 */
object FeedCache {

    private val gson = Gson()
    private val type = object : TypeToken<List<String>>() {}.type
    private const val TAG = "WeiboResume"

    private fun file(c: Context, feed: String) = File(c.filesDir, "feed_$feed.json")

    /** 返回缓存的页面原文列表（解析交给调用方，走 core 的同一套解析） */
    fun load(c: Context, feed: String): List<String>? {
        val f = file(c, feed)
        if (!f.exists()) return null
        val r = runCatching { gson.fromJson<List<String>>(f.readText(), type) }
        r.exceptionOrNull()?.let {
            android.util.Log.d(TAG, "cache parse FAILED: ${it.javaClass.simpleName}: ${it.message}")
        }
        return r.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    fun save(c: Context, feed: String, pages: List<String>) {
        if (pages.isEmpty()) return
        val r = runCatching {
            val tmp = File(c.filesDir, "feed_$feed.json.tmp")
            tmp.writeText(gson.toJson(pages))
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
