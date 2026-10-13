package com.cx.weibo.android.ui.timeline

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cx.weibo.Status
import com.cx.weibo.WeiboTime
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 两个不同的流（实测接口不同，内容也不同） */
enum class FeedKind {
    /** 首页：微博推荐（含广告、非严格时间序） */
    RECOMMEND,
    /** 我的关注：纯关注，天生时间倒序、无广告 */
    FOLLOWING,
}

/** 筛选条件 */
data class FilterState(
    val hideReposts: Boolean = false,
    val onlyWithImages: Boolean = false,
    val hideAds: Boolean = true,
)

data class TimelineUiState(
    val kind: FeedKind? = null,
    val raw: List<Status> = emptyList(),
    val items: List<Status> = emptyList(),
    val filter: FilterState = FilterState(),
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

    /** 按需绑定到某个流；重复调用同 kind 不会重载 */
    fun start(kind: FeedKind) {
        if (_ui.value.kind == kind && _ui.value.raw.isNotEmpty()) return
        _ui.value = TimelineUiState(kind = kind)
        load()
    }

    fun setFilter(f: FilterState) {
        _ui.update { it.copy(filter = f, items = applyFilter(it.raw, f)) }
    }

    fun load() {
        if (_ui.value.loading) return
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) { runCatching { fetch("0") } }
            res.onSuccess { page ->
                _ui.update {
                    it.copy(
                        raw = page.statuses,
                        items = applyFilter(page.statuses, it.filter),
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

    fun refresh() {
        if (_ui.value.refreshing) return
        _ui.update { it.copy(refreshing = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) { runCatching { fetch("0") } }
            res.onSuccess { page ->
                _ui.update {
                    it.copy(
                        raw = page.statuses,
                        items = applyFilter(page.statuses, it.filter),
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

    fun loadMore() {
        val cur = _ui.value
        if (cur.loadingMore || cur.loading || cur.refreshing || cur.endReached) return
        val cursor = cur.cursor ?: return

        _ui.update { it.copy(loadingMore = true) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) { runCatching { fetch(cursor) } }
            res.onSuccess { page ->
                val seen = cur.raw.mapNotNull { it.idstr }.toHashSet()
                val fresh = page.statuses.filter { it.idstr != null && it.idstr !in seen }
                val merged = cur.raw + fresh
                _ui.update {
                    it.copy(
                        raw = merged,
                        items = applyFilter(merged, it.filter),
                        loadingMore = false,
                        endReached = fresh.isEmpty(),
                        cursor = page.nextCursor ?: it.cursor,
                    )
                }
            }.onFailure {
                _ui.update { it.copy(loadingMore = false, endReached = true) }
            }
        }
    }

    private fun fetch(sinceId: String): com.cx.weibo.TimelinePage =
        when (_ui.value.kind) {
            FeedKind.FOLLOWING -> client.followingTimelinePage(sinceId = sinceId)
            else -> client.homeTimelinePage(sinceId = sinceId, count = 20)
        }

    /** 过滤 + 一律按时间倒序（最新在最上面） */
    private fun applyFilter(raw: List<Status>, f: FilterState): List<Status> =
        raw.asSequence()
            .filter { !(f.hideReposts && it.retweetedStatus != null) }
            .filter { !(f.onlyWithImages && it.imageUrls.isEmpty()) }
            .filter { !(f.hideAds && it.isAd == true) }
            .sortedByDescending { WeiboTime.epoch(it.createdAt) }
            .toList()
}
