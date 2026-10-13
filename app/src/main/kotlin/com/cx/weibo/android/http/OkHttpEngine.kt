package com.cx.weibo.android.http

import com.cx.weibo.http.HttpEngine
import com.cx.weibo.http.RawRequest
import com.cx.weibo.http.RawResponse
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/**
 * Android 引擎（OkHttp）。
 *
 * 与 JvmHttpEngine 遵守同一约定：
 *  - **不跟随重定向**（core 需要每跳吸收 Set-Cookie）
 *  - **不管理 cookie**（core 自管）
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
            return RawResponse(resp.code, headers, resp.body?.bytes() ?: ByteArray(0))
        }
    }
}
