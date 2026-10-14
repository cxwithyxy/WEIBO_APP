package com.cx.weibo.android.http

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import uniffi.weibo_core.HttpEngine
import uniffi.weibo_core.RawRequest
import uniffi.weibo_core.RawResponse
import java.util.concurrent.TimeUnit

/**
 * Android 引擎（OkHttp），实现 **Rust 侧**的 `HttpEngine` trait（经 UniFFI 生成的接口）。
 *
 * 与 Rust 的约定一致（非常重要，Rust 的重定向/cookie 逻辑依赖它）：
 *  - **不跟随重定向**（Rust 需要每跳吸收 Set-Cookie）
 *  - **不管理 cookie**（Rust 自管）
 */
class OkHttpEngine : HttpEngine {

    private val client: OkHttpClient = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(25, TimeUnit.SECONDS)
        .build()

    override fun execute(request: RawRequest): RawResponse {
        val rb = Request.Builder().url(request.url)
        request.headers.forEach { (k, v) -> rb.header(k, v) }

        when (request.method.uppercase()) {
            "GET" -> rb.get()
            else -> rb.method(
                request.method,
                (request.body ?: ByteArray(0))
                    .toRequestBody("application/x-www-form-urlencoded".toMediaType())
            )
        }

        client.newCall(rb.build()).execute().use { resp ->
            val headers = LinkedHashMap<String, List<String>>()
            for (i in 0 until resp.headers.size) {
                val name = resp.headers.name(i)
                headers[name] = (headers[name] ?: emptyList()) + resp.headers.value(i)
            }
            return RawResponse(
                status = resp.code.toUShort(),
                headers = headers,
                body = resp.body?.bytes() ?: ByteArray(0),
            )
        }
    }
}
