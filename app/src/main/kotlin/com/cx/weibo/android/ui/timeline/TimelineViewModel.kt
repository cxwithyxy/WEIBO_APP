package com.cx.weibo.android.ui.timeline

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cx.weibo.Status
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class TimelineUiState(
    val items: List<Status> = emptyList(),
    val loading: Boolean = false,
    val refreshing: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    val endReached: Boolean = false,
    val cursor: String? = null,
)

class TimelineViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client

    private val _ui = MutableStateFlow(TimelineUiState())
    val ui: StateFlow<TimelineUiState> = _ui.asStateFlow()

    init { load() }

    /** 首次加载 */
    fun load() {
        if (_ui.value.loading) return
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching { client.homeTimelinePage(sinceId = "0", count = 20) }
            }
            res.onSuccess { page ->
                _ui.update {
                    it.copy(
                        items = page.statuses,
                        loading = false,
                        endReached = page.statuses.isEmpty(),
                        cursor = page.nextCursor,
                    )
                }
            }.onFailure { e ->
                _ui.update { it.copy(loading = false, error = e.message ?: "加载失败") }
            }
        }
    }

    /** 下拉刷新：重新取最新一页 */
    fun refresh() {
        if (_ui.value.refreshing) return
        _ui.update { it.copy(refreshing = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching { client.homeTimelinePage(sinceId = "0", count = 20) }
            }
            res.onSuccess { page ->
                _ui.update {
                    it.copy(
                        items = page.statuses,
                        refreshing = false,
                        endReached = false,
                        cursor = page.nextCursor,
                    )
                }
            }.onFailure { e ->
                _ui.update { it.copy(refreshing = false, error = e.message ?: "刷新失败") }
            }
        }
    }

    /** 触底加载更旧的内容（用服务端游标，按 id 去重） */
    fun loadMore() {
        val cur = _ui.value
        if (cur.loadingMore || cur.loading || cur.refreshing || cur.endReached) return
        val cursor = cur.cursor ?: return

        _ui.update { it.copy(loadingMore = true) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching { client.homeTimelinePage(sinceId = cursor, count = 20) }
            }
            res.onSuccess { page ->
                val seen = cur.items.mapNotNull { it.idstr }.toHashSet()
                val fresh = page.statuses.filter { it.idstr != null && it.idstr !in seen }
                _ui.update {
                    it.copy(
                        items = it.items + fresh,
                        loadingMore = false,
                        endReached = fresh.isEmpty(),
                        cursor = page.nextCursor ?: it.cursor,
                    )
                }
            }.onFailure {
                // 翻页失败不打断已有内容，安静停止
                _ui.update { it.copy(loadingMore = false, endReached = true) }
            }
        }
    }
}
