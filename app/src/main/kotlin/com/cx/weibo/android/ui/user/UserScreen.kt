package com.cx.weibo.android.ui.user

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.cx.weibo.Status
import com.cx.weibo.User
import com.cx.weibo.android.data.WeiboService
import com.cx.weibo.android.ui.timeline.StatusCard
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 某个用户的微博列表页（点头像进入）。
 * 数据源 `/ajax/statuses/mymblog?uid=X&page=N`（实测 page 翻页零重叠）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UserScreen(
    uid: String,
    name: String,
    onBack: () -> Unit,
    onOpenDetail: (String) -> Unit,
    onOpenUser: (String, String) -> Unit,
) {
    val client = WeiboService.client
    val listState = rememberLazyListState()

    var items by remember { mutableStateOf<List<Status>>(emptyList()) }
    var page by remember { mutableIntStateOf(1) }
    var loading by remember { mutableStateOf(true) }
    var loadingMore by remember { mutableStateOf(false) }
    var end by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var user by remember { mutableStateOf<User?>(null) }

    LaunchedEffect(uid) {
        loading = true
        error = null
        val r = withContext(Dispatchers.IO) {
            runCatching {
                val info = runCatching { client.userInfo(uid) }.getOrNull()
                info to client.userTimelinePageRaw(uid, 1).statuses
            }
        }
        r.onSuccess { (info, list) ->
            user = info
            items = list
            page = 2
            end = list.isEmpty()
            loading = false
        }.onFailure {
            error = it.message ?: "加载失败"
            loading = false
        }
    }

    // 触底加载：持续监听可见下标（不用布尔边沿）
    LaunchedEffect(listState) {
        snapshotFlow {
            val info = listState.layoutInfo
            val last = info.visibleItemsInfo.lastOrNull()?.index ?: -1
            last to info.totalItemsCount
        }.collect { (last, total) ->
            if (last >= 0 && total > 0 && last >= total - 3 && !loading && !loadingMore && !end) {
                loadingMore = true
                val r = withContext(Dispatchers.IO) {
                    runCatching { client.userTimelinePageRaw(uid, page).statuses }
                }
                r.onSuccess { list ->
                    val seen = items.mapNotNull { it.idstr }.toHashSet()
                    val fresh = list.filter { it.idstr != null && it.idstr !in seen }
                    items = items + fresh
                    page += 1
                    end = fresh.isEmpty()
                }.onFailure { end = true }
                loadingMore = false
            }
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(user?.screenName ?: name) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                loading && items.isEmpty() -> Box(
                    Modifier.fillMaxSize(), contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator() }

                error != null && items.isEmpty() -> Box(
                    Modifier.fillMaxSize(), contentAlignment = Alignment.Center,
                ) { Text(error ?: "", color = MaterialTheme.colorScheme.error) }

                items.isEmpty() -> Box(
                    Modifier.fillMaxSize(), contentAlignment = Alignment.Center,
                ) { Text("这个用户还没有微博") }

                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                    item { UserHeader(user, name) }
                    items(items, key = { it.idstr ?: it.hashCode().toString() }) { s ->
                        StatusCard(
                            s,
                            onClick = { s.idstr?.let(onOpenDetail) },
                            onOpenUser = onOpenUser,
                        )
                    }
                    if (loadingMore) {
                        item {
                            Box(
                                Modifier.fillMaxWidth().padding(16.dp),
                                contentAlignment = Alignment.Center,
                            ) { CircularProgressIndicator() }
                        }
                    }
                    if (end) {
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

@Composable
private fun UserHeader(user: User?, fallbackName: String) {
    Column(Modifier.fillMaxWidth().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            AsyncImage(
                model = user?.avatar,
                contentDescription = null,
                modifier = Modifier
                    .size(56.dp)
                    .clip(CircleShape),
                contentScale = ContentScale.Crop,
            )
            Spacer(Modifier.width(12.dp))
            Column {
                Text(
                    user?.screenName ?: fallbackName,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                if (user?.description?.isNotBlank() == true) {
                    Spacer(Modifier.height(4.dp))
                    Text(
                        user.description ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Stat("微博", user?.statusesCount)
            Stat("关注", user?.friendsCount)
            Stat("粉丝", user?.followersCount)
        }
    }
}

@Composable
private fun Stat(label: String, value: Long?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            "${value ?: "-"} ",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
