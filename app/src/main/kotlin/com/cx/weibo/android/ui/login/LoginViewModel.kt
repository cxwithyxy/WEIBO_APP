package com.cx.weibo.android.ui.login

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cx.weibo.QrSession
import com.cx.weibo.QrStatus
import com.cx.weibo.android.data.SessionStore
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface LoginUiState {
    /** 正在检查本地是否已有会话 */
    data object Checking : LoginUiState

    /** 正在取二维码 */
    data object LoadingQr : LoginUiState

    /** 二维码已就绪，等待扫码 */
    data class ShowQr(val qr: QrSession, val hint: String) : LoginUiState

    /** 已登录 */
    data object LoggedIn : LoginUiState

    data class Failed(val message: String) : LoginUiState
}

class LoginViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client
    private val cookieFile = SessionStore.cookieFile(app)

    private val _state = MutableStateFlow<LoginUiState>(LoginUiState.Checking)
    val state: StateFlow<LoginUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            val restored = withContext(Dispatchers.IO) { client.restore(cookieFile) }
            if (restored) _state.value = LoginUiState.LoggedIn else startQrLogin()
        }
    }

    fun retry() {
        if (_state.value is LoginUiState.LoadingQr) return
        startQrLogin()
    }

    private fun startQrLogin() {
        _state.value = LoginUiState.LoadingQr
        viewModelScope.launch {
            val qr = withContext(Dispatchers.IO) {
                runCatching {
                    client.auth.prepare()
                    client.auth.createQr()
                }
            }
            qr.onSuccess {
                _state.value = LoginUiState.ShowQr(it, "请用手机微博 App 扫码")
                pollLoop(it.qrid)
            }.onFailure {
                _state.value = LoginUiState.Failed(it.message ?: "取二维码失败")
            }
        }
    }

    private suspend fun pollLoop(qrid: String) {
        while (true) {
            val st = withContext(Dispatchers.IO) {
                runCatching { client.auth.poll(qrid) }.getOrNull()
            }
            if (st == null) {
                _state.value = LoginUiState.Failed("轮询失败，请检查网络")
                return
            }
            when (st.state) {
                QrStatus.State.CONFIRMED -> {
                    val ok = withContext(Dispatchers.IO) {
                        runCatching {
                            st.url?.let { client.auth.complete(it) }
                            if (!client.isLoggedIn()) return@runCatching false
                            client.save(cookieFile)
                            client.restore(cookieFile)   // 回读校验落盘
                        }.getOrDefault(false)
                    }
                    _state.value = if (ok) LoginUiState.LoggedIn
                    else LoginUiState.Failed("已确认，但未取得会话 cookie")
                    return
                }

                QrStatus.State.EXPIRED, QrStatus.State.ERROR -> {
                    _state.value = LoginUiState.Failed(st.message ?: "二维码已失效")
                    return
                }

                QrStatus.State.SCANNED -> {
                    val cur = _state.value
                    if (cur is LoginUiState.ShowQr) {
                        _state.value = cur.copy(hint = "已扫描，请在手机上点「确认登录」")
                    }
                }

                QrStatus.State.WAITING -> Unit
            }
            delay(2000)
        }
    }
}
