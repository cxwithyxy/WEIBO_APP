package com.cx.weibo.android.ui.search

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import uniffi.weibo_core.Status
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SearchUiState(
    val query: String = "",
    val items: List<Status> = emptyList(),
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    val searched: Boolean = false,
    val page: Int = 1,
    val endReached: Boolean = false,
)

class SearchViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client

    private val _ui = MutableStateFlow(SearchUiState())
    val ui: StateFlow<SearchUiState> = _ui.asStateFlow()

    fun onQueryChange(q: String) = _ui.update { it.copy(query = q) }

    /** 提交搜索（重置到第 1 页） */
    fun submit(seed: String? = null) {
        val q = (seed ?: _ui.value.query).trim()
        if (q.isEmpty()) return
        _ui.update { it.copy(query = q, loading = true, searched = true, error = null, page = 1, endReached = false) }

        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) { runCatching { client.search(q, count = 20u, page = 1u) } }
            res.onSuccess { list ->
                _ui.update { it.copy(items = list, loading = false, endReached = list.isEmpty()) }
            }.onFailure { e ->
                _ui.update { it.copy(items = emptyList(), loading = false, error = e.message ?: "搜索失败", endReached = true) }
            }
        }
    }

    fun loadMore() {
        val cur = _ui.value
        if (cur.loadingMore || cur.loading || cur.endReached || cur.query.isBlank()) return

        _ui.update { it.copy(loadingMore = true) }
        viewModelScope.launch {
            val nextPage = cur.page + 1
            val res = withContext(Dispatchers.IO) { runCatching { client.search(cur.query, count = 20u, page = nextPage.toUInt()) } }
            res.onSuccess { list ->
                val seen = cur.items.mapNotNull { it.idstr }.toHashSet()
                val fresh = list.filter { it.idstr != null && it.idstr !in seen }
                _ui.update {
                    it.copy(
                        items = it.items + fresh,
                        loadingMore = false,
                        page = nextPage,
                        endReached = fresh.isEmpty(),
                    )
                }
            }.onFailure {
                _ui.update { it.copy(loadingMore = false, endReached = true) }
            }
        }
    }
}
