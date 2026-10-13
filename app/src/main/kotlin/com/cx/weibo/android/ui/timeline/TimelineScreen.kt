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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.flow.first

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimelineScreen(
    kind: FeedKind,
    onOpenDetail: (String) -> Unit,
) {
    val vm: TimelineViewModel = viewModel(key = "feed-${kind.name}")
    LaunchedEffect(kind) { vm.start(kind) }

    val ui by vm.ui.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

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

    // 重开后跳回上次阅读的位置（每条流各记一份）
    // 关键：要等列表**真正布局出来**再滚 —— 否则同一帧里的 scrollToItem
    // 会被 LazyColumn 的首次布局覆盖掉（踩过）。
    var restored by remember(kind) { mutableStateOf(false) }
    LaunchedEffect(ui.items, ui.loading) {
        if (restored || ui.loading) return@LaunchedEffect
        val a = ui.anchorId
            ?: return@LaunchedEffect
        val idx = ui.items.indexOfFirst { it.idstr == a }
        if (idx < 0) {
            restored = true
            return@LaunchedEffect
        }
        snapshotFlow { listState.layoutInfo.totalItemsCount }.first { it > idx }
        listState.scrollToItem(idx)
        restored = true
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
                        StatusCard(s, onClick = { s.idstr?.let(onOpenDetail) })
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
