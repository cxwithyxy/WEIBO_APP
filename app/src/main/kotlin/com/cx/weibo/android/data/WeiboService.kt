package com.cx.weibo.android.data

import com.cx.weibo.WeiboClient
import com.cx.weibo.android.http.OkHttpEngine

/**
 * 全局单例。
 *
 * cookie 由 `WeiboHttp` 在内存里维护，所以整个 App 必须共用**同一个**
 * `WeiboClient` 实例，否则登录态不共享。
 */
object WeiboService {
    val engine = OkHttpEngine()
    val client: WeiboClient = WeiboClient(engine)
}
