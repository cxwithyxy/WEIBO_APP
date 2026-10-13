package com.cx.weibo.android.ui.search

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cx.weibo.android.ui.timeline.StatusCard

@Composable
fun SearchScreen(
    seed: String,
    onSeedConsumed: () -> Unit,
    onOpenDetail: (String) -> Unit,
    vm: SearchViewModel = viewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

    // 从热搜点进来的词
    LaunchedEffect(seed) {
        if (seed.isNotBlank()) {
            vm.submit(seed)
            onSeedConsumed()
        }
    }

    val nearBottom by remember {
        derivedStateOf {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            info.totalItemsCount > 0 && last >= info.totalItemsCount - 3
        }
    }
    LaunchedEffect(nearBottom) { if (nearBottom) vm.loadMore() }

    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = ui.query,
            onValueChange = vm::onQueryChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            placeholder = { Text("搜索微博") },
            singleLine = true,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { vm.submit() }),
        )

        when {
            ui.loading -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) { CircularProgressIndicator() }

            ui.error != null -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text(ui.error ?: "", color = MaterialTheme.colorScheme.error)
            }

            !ui.searched -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                Text("输入关键词后回车搜索", style = MaterialTheme.typography.bodyMedium)
            }

            ui.items.isEmpty() -> Box(
                Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) { Text("没有搜到相关微博") }

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
                if (ui.endReached && ui.items.isNotEmpty()) {
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
