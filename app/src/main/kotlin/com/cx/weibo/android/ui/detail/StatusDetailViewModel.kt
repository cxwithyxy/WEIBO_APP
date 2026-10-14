package com.cx.weibo.android.ui.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import uniffi.weibo_core.Comment
import uniffi.weibo_core.Status
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class DetailUiState(
    val mid: String? = null,
    val status: Status? = null,
    val comments: List<Comment> = emptyList(),
    val totalComments: Int? = null,
    val loading: Boolean = false,
    val loadingMore: Boolean = false,
    val error: String? = null,
    val endReached: Boolean = false,
    val cursor: Long = 0L,
)

class StatusDetailViewModel(app: Application) : AndroidViewModel(app) {

    private val client = WeiboService.client

    private val _ui = MutableStateFlow(DetailUiState())
    val ui: StateFlow<DetailUiState> = _ui.asStateFlow()

    /** 进入详情页时调用；同一条微博不会重复加载 */
    fun start(mid: String) {
        if (_ui.value.mid == mid && _ui.value.status != null) return
        _ui.value = DetailUiState(mid = mid, loading = true)

        viewModelScope.launch {
            val statusRes = withContext(Dispatchers.IO) { runCatching { client.statusDetail(mid) } }
            // flow=1（按时间）才能翻页；按热度翻不了
            val commentRes = withContext(Dispatchers.IO) {
                runCatching { client.commentsPage(mid, count = 20u, maxId = 0L, flow = 1u) }
            }

            val page = commentRes.getOrNull()
            _ui.update {
                it.copy(
                    status = statusRes.getOrNull(),
                    comments = page?.comments ?: emptyList(),
                    totalComments = page?.totalNumber,
                    cursor = page?.nextMaxId ?: 0L,
                    endReached = page?.nextMaxId == null || page.nextMaxId == 0L,
                    loading = false,
                    error = statusRes.exceptionOrNull()?.message ?: commentRes.exceptionOrNull()?.message,
                )
            }
        }
    }

    fun loadMoreComments() {
        val cur = _ui.value
        val mid = cur.mid ?: return
        if (cur.loadingMore || cur.loading || cur.endReached) return

        _ui.update { it.copy(loadingMore = true) }
        viewModelScope.launch {
            val res = withContext(Dispatchers.IO) {
                runCatching { client.commentsPage(mid, count = 20u, maxId = cur.cursor, flow = 1u) }
            }
            res.onSuccess { page ->
                _ui.update {
                    it.copy(
                        comments = it.comments + page.comments,
                        loadingMore = false,
                        endReached = page.nextMaxId == null || page.nextMaxId == 0L,
                        cursor = page.nextMaxId ?: 0L,
                    )
                }
            }.onFailure {
                _ui.update { it.copy(loadingMore = false, endReached = true) }
            }
        }
    }
}
