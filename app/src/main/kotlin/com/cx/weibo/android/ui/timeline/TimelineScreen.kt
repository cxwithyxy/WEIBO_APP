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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

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

    val nearBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            info.totalItemsCount > 0 && last >= info.totalItemsCount - 3
        }
    }
    LaunchedEffect(nearBottom) { if (nearBottom) vm.loadMore() }

    Column(Modifier.fillMaxSize()) {
        FilterBar(ui.filter, ui.raw.size, ui.items.size, vm::setFilter)
        HorizontalDivider()

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
