package com.cx.weibo.android.ui.timeline

import android.app.Application
import android.content.Context
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.cx.weibo.Status
import com.cx.weibo.TimelineRaw
import com.cx.weibo.WeiboTime
import com.cx.weibo.android.data.FeedCache
import com.cx.weibo.android.data.FeedSnapshot
import com.cx.weibo.android.data.Prefs
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class FeedKind {
    /** 首页：微博推荐（含广告、非严格时间序） */
    RECOMMEND,

    /** 我的关注：纯关注，天生时间倒序、无广告 */
    FOLLOWING,
}

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
    /** 上次读到哪条（用于重开后跳回去） */
    val anchorId: String? = null,
    /** 「恢复位置」是否已完成 —— 只在 VM 生命周期内做一次，
     *  否则每次切 tab 回来都会重新跳一次（踩过）。*/
    val restored: Boolean = false,
)

private data class LoadResult(
    val raw: List<Status>,
    val items: List<Status>,
    val cursor: String?,
)

private data class MoreResult(
    val load: LoadResult,
    val noMore: Boolean,
    val rawPage: String,
)

class TimelineViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client
    private val ctx: Context = app.applicationContext

    /** 已加载页面的**响应原文**（本地缓存用） */
    private var pages: List<String> = emptyList()

    private val _ui = MutableStateFlow(TimelineUiState())
    val ui: StateFlow<TimelineUiState> = _ui.asStateFlow()

    /** 绑定到某个流；已绑过就不重载（切 tab 回来不闪） */
    fun start(kind: FeedKind) {
        if (_ui.value.kind == kind && _ui.value.raw.isNotEmpty()) return

        val anchor = Prefs.anchor(ctx, kind.name)
        val cached = FeedCache.load(ctx, kind.name)

        if (cached != null) {
            // 命中缓存：用**和网络完全相同的解析路径**还原，秒开且能精确回到原位
            pages = cached.pages
            val statuses = cached.pages.flatMap { client.parseTimelineRaw(it) }
            if (statuses.isNotEmpty()) {
                _ui.value = TimelineUiState(
                    kind = kind,
                    raw = statuses,
                    items = applyFilter(statuses, FilterState()),
                    anchorId = anchor,
                    cursor = cached.cursor,   // ⚠ 必须还原，否则「加载更多」断掉
                )
                return
            }
        }
        _ui.value = TimelineUiState(kind = kind, anchorId = anchor)
        load()
    }

    /** 记录阅读位置（顶部可见那条） */
    fun saveAnchor(statusId: String?) {
        val kind = _ui.value.kind ?: return
        Prefs.setAnchor(ctx, kind.name, statusId)
    }

    /** 位置恢复完成（只标一次） */
    fun markRestored() {
        _ui.update { it.copy(restored = true) }
    }

    fun setFilter(f: FilterState) {
        _ui.update { it.copy(filter = f) }
        viewModelScope.launch {
            val items = withContext(Dispatchers.IO) { applyFilter(_ui.value.raw, f) }
            _ui.update { it.copy(items = items) }
        }
    }

    /** 首次加载（无缓存时） */
    fun load() {
        if (_ui.value.loading) return
        _ui.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching {
                    val p = fetchPage(null)
                    LoadResult(p.statuses, applyFilter(p.statuses, _ui.value.filter), p.nextCursor) to listOf(p.raw)
                }
            }
            res.onSuccess { (r, rawPages) ->
                pages = rawPages
                persist(r.cursor)
                _ui.update {
                    it.copy(
                        raw = r.raw,
                        items = r.items,
                        loading = false,
                        endReached = r.raw.isEmpty(),
                        cursor = r.cursor,
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
            val res = withContext(Dispatchers.IO) {
                runCatching {
                    val p = fetchPage(null)
                    LoadResult(p.statuses, applyFilter(p.statuses, _ui.value.filter), p.nextCursor) to listOf(p.raw)
                }
            }
            res.onSuccess { (r, rawPages) ->
                pages = rawPages
                persist(r.cursor)
                _ui.update {
                    it.copy(
                        raw = r.raw,
                        items = r.items,
                        refreshing = false,
                        endReached = false,
                        cursor = r.cursor,
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
            val res = withContext(Dispatchers.IO) {
                runCatching {
                    val p = fetchPage(cursor)
                    val seen = cur.raw.mapNotNull { it.idstr }.toHashSet()
                    val fresh = p.statuses.filter { it.idstr != null && it.idstr !in seen }
                    val merged = cur.raw + fresh
                    MoreResult(
                        load = LoadResult(merged, applyFilter(merged, cur.filter), p.nextCursor ?: cursor),
                        noMore = fresh.isEmpty(),
                        rawPage = p.raw,
                    )
                }
            }
            res.onSuccess { m ->
                pages = pages + m.rawPage
                persist(m.load.cursor)
                _ui.update {
                    it.copy(
                        raw = m.load.raw,
                        items = m.load.items,
                        loadingMore = false,
                        endReached = m.noMore,
                        cursor = m.load.cursor,
                    )
                }
            }.onFailure {
                _ui.update { it.copy(loadingMore = false, endReached = true) }
            }
        }
    }

    // ---------------- 内部 ----------------

    private fun persist(cursor: String? = _ui.value.cursor) {
        val kind = _ui.value.kind ?: return
        FeedCache.save(ctx, kind.name, FeedSnapshot(pages, cursor))
    }

    private fun fetchPage(cursor: String?): TimelineRaw =
        when (_ui.value.kind) {
            // 关注流：游标是「下一页页码」（它的 since_id 翻页实测无效）
            FeedKind.FOLLOWING -> client.followingTimelinePageRaw(page = cursor?.toIntOrNull() ?: 1)
            // 推荐流：游标是 since_id（实测零重叠）
            else -> client.homeTimelinePageRaw(sinceId = cursor ?: "0", count = 20)
        }

    /** 过滤 + 一律按时间倒序（最新在最上面） */
    private fun applyFilter(raw: List<Status>, f: FilterState): List<Status> =
        raw.asSequence()
            .filter { !(f.hideReposts && it.retweetedStatus != null) }
            .filter { !(f.onlyWithImages && it.imageUrls.isEmpty()) }
            .filter { !(f.hideAds && it.isAdFlag) }
            .sortedByDescending { WeiboTime.epoch(it.createdAt) }
            .toList()
}
