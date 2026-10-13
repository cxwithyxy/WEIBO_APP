package com.cx.weibo.http

/**
 * 一次「不跟随重定向、不管理 cookie」的原始请求。
 * POST 的 body 必须已按 application/x-www-form-urlencoded 编码。
 */
data class RawRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray? = null,
)

/** 原始响应。引擎**不得**跟随重定向、不得管理 cookie、不得重试。 */
class RawResponse(
    val status: Int,
    headers: Map<String, List<String>>,
    val body: ByteArray,
) {
    private val lower: Map<String, List<String>> =
        headers.entries.associate { it.key.lowercase() to it.value }

    fun header(name: String): String? = lower[name.lowercase()]?.firstOrNull()
    fun headerValues(name: String): List<String> = lower[name.lowercase()] ?: emptyList()

    val bodyText: String get() = String(body, Charsets.UTF_8)
}

/**
 * 平台 HTTP 引擎。
 *
 * 实现约定（非常重要，core 的重定向/cookie 逻辑依赖它）：
 *  - **不跟随重定向**，原样返回 3xx 与 Location
 *  - **不管理 cookie**，原样回传所有 Set-Cookie
 *  - **不自动重试**
 */
interface HttpEngine {
    fun execute(request: RawRequest): RawResponse
}
