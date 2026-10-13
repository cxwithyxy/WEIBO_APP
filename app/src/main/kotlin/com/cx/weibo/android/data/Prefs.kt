package com.cx.weibo.android.data

import android.content.Context

/** 轻量本地偏好（主题 + 各信息流的阅读位置） */
object Prefs {

    private const val FILE = "weibo_prefs"

    private fun sp(c: Context) = c.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    // ---------------- 主题 ----------------

    fun themeMode(c: Context): String =
        sp(c).getString("theme_mode", "SYSTEM") ?: "SYSTEM"

    fun setThemeMode(c: Context, mode: String) {
        sp(c).edit().putString("theme_mode", mode).apply()
    }

    // ---------------- 阅读位置（锚点 = 顶部可见微博的 id）----------------

    fun anchor(c: Context, feed: String): String? =
        sp(c).getString("anchor_$feed", null)

    fun setAnchor(c: Context, feed: String, statusId: String?) {
        sp(c).edit().apply {
            if (statusId == null) remove("anchor_$feed") else putString("anchor_$feed", statusId)
        }.apply()
    }
}
