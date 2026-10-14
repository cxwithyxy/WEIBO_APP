package com.cx.weibo.android.ui.hot

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import uniffi.weibo_core.HotBandItem
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class HotUiState(
    val items: List<HotBandItem> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
)

class HotViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client

    private val _ui = MutableStateFlow(HotUiState())
    val ui: StateFlow<HotUiState> = _ui.asStateFlow()

    init { load() }

    fun load() {
        if (_ui.value.loading) return
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching { client.hotBand(bandId = 1u, count = 50u) }
            }
            res.onSuccess { list ->
                _ui.update { it.copy(items = list, loading = false) }
            }.onFailure { e ->
                _ui.update { it.copy(loading = false, error = e.message ?: "加载失败") }
            }
        }
    }
}
