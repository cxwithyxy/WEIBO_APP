package com.cx.weibo

// ------------------------------------------------------------------
// 扫码登录（微博 SSO v2）
//
//   1. prepare()      访问登录页，建立会话（下发 X-CSRF-TOKEN）
//   2. createQr()     取二维码 qrid + 图片 URL
//   3. poll(qrid)     轮询扫描状态
//   4. complete(url)  跟随回调，拿到 SUB 等 cookie
// ------------------------------------------------------------------

data class QrSession(val qrid: String, val imageUrl: String)

data class QrStatus(val state: State, val url: String? = null, val message: String? = null) {
    enum class State { WAITING, SCANNED, EXPIRED, CONFIRMED, ERROR }
}

internal data class QrImageResp(val retcode: Int? = null, val msg: String? = null, val data: QrImageData? = null)
internal data class QrImageData(val qrid: String? = null, val image: String? = null)

internal data class QrCheckResp(val retcode: Int? = null, val msg: String? = null, val data: QrCheckData? = null)
internal data class QrCheckData(val url: String? = null)

class WeiboAuth(private val http: WeiboHttp) {

    companion object {
        const val SIGNIN = "$HOST_PASSPORT/sso/signin?entry=wapsso&source=wapssowb"
        private const val VER = "20250520"
        const val POST_LOGIN_URL = "https://m.weibo.cn/"
    }

    private val referer: String = SIGNIN

    /** 步骤 1：先访问登录页，拿 X-CSRF-TOKEN 等 cookie */
    fun prepare() {
        http.get(SIGNIN)
    }

    /** 步骤 2：取二维码 */
    fun createQr(size: Int = 300): QrSession {
        val json = http.get("$HOST_PASSPORT/sso/v2/qrcode/image?entry=wapsso&size=$size", referer = referer)
        val r = http.gson.fromJson(json, QrImageResp::class.java)
        val d = r?.data ?: throw WeiboException("二维码获取失败 retcode=${r?.retcode} msg=${r?.msg}")
        val qrid = d.qrid ?: throw WeiboException("响应缺少 qrid")
        val image = d.image ?: throw WeiboException("响应缺少 image")
        return QrSession(qrid, image)
    }

    /** 步骤 3：轮询一次扫描状态 */
    fun poll(qrid: String): QrStatus {
        val url = buildString {
            append("$HOST_PASSPORT/sso/v2/qrcode/check")
            append("?entry=wapsso&source=wapssowb")
            append("&url=").append(http.enc(POST_LOGIN_URL))
            append("&qrid=").append(http.enc(qrid))
            append("&disp=&rid=norid&ver=").append(VER)
        }
        val json = http.get(url, referer = referer)
        val r = http.gson.fromJson(json, QrCheckResp::class.java)
            ?: return QrStatus(QrStatus.State.ERROR, message = "空响应")
        return when (r.retcode) {
            20000000 -> QrStatus(QrStatus.State.CONFIRMED, url = r.data?.url, message = r.msg)
            50114001 -> QrStatus(QrStatus.State.WAITING, message = r.msg)
            50114002 -> QrStatus(QrStatus.State.SCANNED, message = r.msg)
            50114003, 50114004, 50114015 -> QrStatus(QrStatus.State.EXPIRED, message = r.msg)
            else -> QrStatus(QrStatus.State.ERROR, message = r.msg ?: "retcode=${r.retcode}")
        }
    }

    /** 步骤 4：已确认 → 跟随回调链，cookie 自动落到 WeiboHttp 的 CookieManager */
    fun complete(url: String) {
        http.get(url, referer = referer)
    }

    /**
     * 阻塞式完整登录：取码 → 回调展示二维码 → 等待扫描 → 完成。
     * @param onQr 回调，把 qrid 和图片 URL 交给调用方展示
     * @param onState 状态变化回调（可选）
     */
    fun loginBlocking(
        timeoutSeconds: Int = 180,
        pollIntervalMs: Long = 2000,
        onQr: (QrSession) -> Unit,
        onState: (QrStatus) -> Unit = {},
    ): Boolean {
        if (!http.isLoggedIn()) prepare()
        val session = createQr()
        onQr(session)

        val deadline = System.currentTimeMillis() + timeoutSeconds * 1000L
        while (System.currentTimeMillis() < deadline) {
            val st = poll(session.qrid)
            onState(st)
            when (st.state) {
                QrStatus.State.CONFIRMED -> {
                    st.url?.let { complete(it) }
                    return http.isLoggedIn()
                }
                QrStatus.State.EXPIRED, QrStatus.State.ERROR -> return false
                else -> Thread.sleep(pollIntervalMs)
            }
        }
        return false
    }
}
