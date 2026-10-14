package com.cx.weibo.android.ui.profile

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import uniffi.weibo_core.Status
import uniffi.weibo_core.User
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ProfileUiState(
    val user: User? = null,
    val items: List<Status> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
)

class ProfileViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client

    private val _ui = MutableStateFlow(ProfileUiState())
    val ui: StateFlow<ProfileUiState> = _ui.asStateFlow()

    init { load() }

    fun load() {
        if (_ui.value.loading) return
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val uid = client.uid()
            if (uid == null) {
                _ui.update { it.copy(loading = false, error = "未取得账号信息") }
                return@launch
            }
            val userRes = withContext(Dispatchers.IO) { runCatching { client.profile(uid) } }
            val blogRes = withContext(Dispatchers.IO) { runCatching { client.myBlog(uid = uid, page = 1u) } }
            _ui.update {
                it.copy(
                    user = userRes.getOrNull(),
                    items = blogRes.getOrNull() ?: emptyList(),
                    loading = false,
                    error = userRes.exceptionOrNull()?.message,
                )
            }
        }
    }
}
