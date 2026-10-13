package com.cx.weibo

import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * 微博时间工具。
 *
 * 服务端 `created_at` 形如 `Tue Oct 13 15:21:43 +0800 2026`，
 * 这里统一转成 `YYYY/MM/DD HH:mm:SS`（本地时区）。
 */
object WeiboTime {

    private val IN = DateTimeFormatter.ofPattern("EEE MMM dd HH:mm:ss Z yyyy", Locale.US)
    private val OUT = DateTimeFormatter.ofPattern("yyyy/MM/dd HH:mm:ss")

    /** 解析成 Instant；失败返回 null */
    fun parse(raw: String?): Instant? =
        raw?.let {
            runCatching { OffsetDateTime.parse(it.trim(), IN).toInstant() }.getOrNull()
        }

    /** 格式化为 YYYY/MM/DD HH:mm:SS（解析失败时原样返回） */
    fun format(raw: String?): String {
        val inst = parse(raw) ?: return raw ?: ""
        return OUT.format(inst.atZone(ZoneId.systemDefault()))
    }

    /** 排序用：越大越新；缺失/解析失败视为最旧 */
    fun epoch(raw: String?): Long = parse(raw)?.toEpochMilli() ?: Long.MIN_VALUE
}
