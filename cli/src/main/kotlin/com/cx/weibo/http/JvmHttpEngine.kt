package com.cx.weibo.http

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

/**
 * JVM 引擎（java.net.http）。
 *
 * 刻意关闭自动重定向，交由 core 的 WeiboHttp 处理 ——
 * 因为它需要每一跳都吸收 Set-Cookie（微博登录依赖这个）。
 */
class JvmHttpEngine : HttpEngine {

    private val client: HttpClient = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NEVER)
        .connectTimeout(Duration.ofSeconds(20))
        .build()

    override fun execute(request: RawRequest): RawResponse {
        val b = HttpRequest.newBuilder(URI.create(request.url))
            .timeout(Duration.ofSeconds(25))
        request.headers.forEach { (k, v) -> b.header(k, v) }
        b.method(
            request.method,
            request.body?.let { HttpRequest.BodyPublishers.ofByteArray(it) }
                ?: HttpRequest.BodyPublishers.noBody()
        )
        val r = client.send(b.build(), HttpResponse.BodyHandlers.ofByteArray())
        return RawResponse(r.statusCode(), r.headers().map(), r.body())
    }
}
