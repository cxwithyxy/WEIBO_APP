package com.cx.weibo.android.ui.timeline

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import android.widget.Toast
import com.cx.weibo.Status
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimelineScreen(
    kind: FeedKind,
    listState: LazyListState,
    onOpenDetail: (String) -> Unit,
    onOpenUser: (String, String) -> Unit,
) {
    val vm: TimelineViewModel = viewModel(key = "feed-${kind.name}")
    LaunchedEffect(kind) { vm.start(kind) }

    val ui by vm.ui.collectAsStateWithLifecycle()

    // 触底加载：改成**持续监听可见下标**，而不是「布尔值的边沿」——
    // 旧写法（LaunchedEffect(nearBottom)）到底后只触发一次，之后就再也不加载了（踩过）。
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            last to info.totalItemsCount
        }.collect { (last, total) ->
            if (last >= 0 && total > 0 && last >= total - 3) vm.loadMore()
        }
    }

    // 重开后跳回上次阅读的位置。
    // 只在「这个 VM 还没恢复过」时做一次 —— restored 存在 VM 里，
    // 所以切 tab 回来不会重新跳（否则就是用户反馈的「跳到一个奇怪位置」）。
    LaunchedEffect(ui.items, ui.loading, ui.restored) {
        if (ui.restored || ui.loading) return@LaunchedEffect
        val a = ui.anchorId
        if (a == null) {
            vm.markRestored()
            return@LaunchedEffect
        }
        val idx = ui.items.indexOfFirst { it.idstr == a }
        if (idx < 0) {
            vm.markRestored()
            return@LaunchedEffect
        }
        snapshotFlow { listState.layoutInfo.totalItemsCount }.first { it > idx }
        listState.scrollToItem(idx)
        vm.markRestored()
    }

    // 持续记录当前顶部那条
    // 注意：必须把 totalItemsCount 也纳入快照 —— 否则列表加载完成时
    // firstVisibleItemIndex 仍是 0（没变化），snapshotFlow 不会再发射，锚点就存不上。
    LaunchedEffect(listState) {
        snapshotFlow {
            listState.firstVisibleItemIndex to listState.layoutInfo.totalItemsCount
        }.collect { (idx, _) ->
            vm.ui.value.items.getOrNull(idx)?.idstr?.let { vm.saveAnchor(it) }
        }
    }

    // ---------------- 互动：点赞 / 转发 / 评论 ----------------
    val client = WeiboService.client
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val likedIds = remember { mutableStateMapOf<String, Boolean>() }
    var repostTarget by remember { mutableStateOf<Status?>(null) }
    var commentTarget by remember { mutableStateOf<Status?>(null) }
    var dialogText by remember { mutableStateOf("") }
    var dialogBusy by remember { mutableStateOf(false) }

    fun toast(msg: String) = Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()

    fun toggleLike(s: Status) {
        val id = s.idstr ?: return
        val wasLiked = likedIds[id] == true
        likedIds[id] = !wasLiked // 乐观更新
        scope.launch {
            val r = withContext(Dispatchers.IO) {
                runCatching { if (wasLiked) client.cancelLike(id) else client.setLike(id) }
            }
            r.onSuccess { toast(if (wasLiked) "已取消赞" else "已点赞") }
                .onFailure {
                    likedIds[id] = wasLiked // 失败回滚
                    toast("操作失败：${it.message}")
                }
        }
    }

    // 转发弹窗
    repostTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { if (!dialogBusy) { repostTarget = null; dialogText = "" } },
            title = { Text("转发") },
            text = {
                OutlinedTextField(
                    value = dialogText,
                    onValueChange = { dialogText = it },
                    placeholder = { Text("说点什么（可留空）") },
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !dialogBusy,
                    onClick = {
                        val id = target.idstr ?: return@TextButton
                        dialogBusy = true
                        scope.launch {
                            val r = withContext(Dispatchers.IO) {
                                runCatching { client.repost(id, dialogText) }
                            }
                            dialogBusy = false
                            r.onSuccess {
                                toast("已转发"); repostTarget = null; dialogText = ""
                            }.onFailure { toast("转发失败：${it.message}") }
                        }
                    },
                ) { Text(if (dialogBusy) "发送中…" else "转发") }
            },
            dismissButton = {
                TextButton(onClick = { repostTarget = null; dialogText = "" }) { Text("取消") }
            },
        )
    }

    // 评论弹窗
    commentTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { if (!dialogBusy) { commentTarget = null; dialogText = "" } },
            title = { Text("评论") },
            text = {
                OutlinedTextField(
                    value = dialogText,
                    onValueChange = { dialogText = it },
                    placeholder = { Text("写评论…") },
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    enabled = !dialogBusy && dialogText.isNotBlank(),
                    onClick = {
                        val id = target.idstr ?: return@TextButton
                        dialogBusy = true
                        scope.launch {
                            val r = withContext(Dispatchers.IO) {
                                runCatching { client.comment(id, dialogText) }
                            }
                            dialogBusy = false
                            r.onSuccess {
                                toast("已评论"); commentTarget = null; dialogText = ""
                            }.onFailure { toast("评论失败：${it.message}") }
                        }
                    },
                ) { Text(if (dialogBusy) "发送中…" else "发送") }
            },
            dismissButton = {
                TextButton(onClick = { commentTarget = null; dialogText = "" }) { Text("取消") }
            },
        )
    }

    Column(Modifier.fillMaxSize()) {
        FilterBar(ui.filter, ui.raw.size, ui.items.size, vm::setFilter)
        HorizontalDivider(color = MaterialTheme.colorScheme.outline)

        PullToRefreshBox(
            isRefreshing = ui.refreshing,
            onRefresh = { vm.refresh() },
            modifier = Modifier.fillMaxSize(),
        ) {
            when {
                ui.loading && ui.raw.isEmpty() -> Centered { CircularProgressIndicator() }

                ui.error != null && ui.raw.isEmpty() -> Centered {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            ui.error ?: "",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = { vm.load() }) { Text("重试") }
                    }
                }

                ui.items.isEmpty() -> Centered {
                    Text(
                        if (ui.raw.isEmpty()) "这里还没有内容" else "当前筛选条件下没有内容",
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }

                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                    items(ui.items, key = { it.idstr ?: it.hashCode().toString() }) { s ->
                        StatusCard(
                            status = s,
                            onClick = { s.idstr?.let(onOpenDetail) },
                            onOpenUser = onOpenUser,
                            onLike = { toggleLike(s) },
                            onRepost = { repostTarget = s; dialogText = "" },
                            onComment = { commentTarget = s; dialogText = "" },
                            liked = likedIds[s.idstr] == true,
                        )
                    }
                    if (ui.loadingMore) {
                        item {
                            Box(
                                Modifier.fillMaxWidth().padding(16.dp),
                                contentAlignment = Alignment.Center,
                            ) { CircularProgressIndicator() }
                        }
                    }
                    if (ui.endReached) {
                        item {
                            Box(
                                Modifier.fillMaxWidth().padding(16.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(
                                    "没有更多了",
                                    style = MaterialTheme.typography.labelSmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FilterBar(
    f: FilterState,
    rawCount: Int,
    shownCount: Int,
    onChange: (FilterState) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        FilterChip(
            selected = f.hideAds,
            onClick = { onChange(f.copy(hideAds = !f.hideAds)) },
            label = { Text("去广告") },
        )
        Spacer(Modifier.width(8.dp))
        FilterChip(
            selected = f.hideReposts,
            onClick = { onChange(f.copy(hideReposts = !f.hideReposts)) },
            label = { Text("只看原创") },
        )
        Spacer(Modifier.width(8.dp))
        FilterChip(
            selected = f.onlyWithImages,
            onClick = { onChange(f.copy(onlyWithImages = !f.onlyWithImages)) },
            label = { Text("只看带图") },
        )
        Spacer(Modifier.width(12.dp))
        Text(
            "$shownCount/$rawCount",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun Centered(content: @Composable () -> Unit) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
}
