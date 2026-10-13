package com.cx.weibo.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import com.cx.weibo.android.ui.hot.HotScreen
import com.cx.weibo.android.ui.profile.ProfileScreen
import com.cx.weibo.android.ui.search.SearchScreen
import com.cx.weibo.android.ui.timeline.FeedKind
import com.cx.weibo.android.ui.timeline.TimelineScreen

private data class Tab(val title: String, val icon: ImageVector)

private val TABS = listOf(
    Tab("首页", Icons.Filled.Home),
    Tab("关注", Icons.Filled.Favorite),
    Tab("搜索", Icons.Filled.Search),
    Tab("热搜", Icons.Filled.Star),
    Tab("我的", Icons.Filled.Person),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainTabs(
    themeMode: String,
    onThemeChange: (String) -> Unit,
    onExit: () -> Unit,
    onOpenDetail: (String) -> Unit,
) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var seed by remember { mutableStateOf("") }
    var showExit by remember { mutableStateOf(false) }

    // 返回键：不在首页先回首页；已在首页则弹确认退出
    BackHandler(enabled = true) {
        if (tab != 0) tab = 0 else showExit = true
    }

    if (showExit) {
        AlertDialog(
            onDismissRequest = { showExit = false },
            title = { Text("退出") },
            text = { Text("确定要退出微博客户端吗？") },
            confirmButton = {
                TextButton(onClick = {
                    showExit = false
                    onExit()
                }) { Text("退出") }
            },
            dismissButton = {
                TextButton(onClick = { showExit = false }) { Text("取消") }
            },
        )
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text(TABS[tab].title) }) },
        bottomBar = {
            NavigationBar {
                TABS.forEachIndexed { i, t ->
                    NavigationBarItem(
                        selected = tab == i,
                        onClick = { tab = i },
                        icon = { Icon(t.icon, contentDescription = t.title) },
                        label = { Text(t.title) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when (tab) {
                0 -> TimelineScreen(kind = FeedKind.RECOMMEND, onOpenDetail = onOpenDetail)

                1 -> TimelineScreen(kind = FeedKind.FOLLOWING, onOpenDetail = onOpenDetail)

                2 -> SearchScreen(
                    seed = seed,
                    onSeedConsumed = { seed = "" },
                    onOpenDetail = onOpenDetail,
                )

                3 -> HotScreen(
                    onSearchWord = { word ->
                        seed = word
                        tab = 2
                    }
                )

                else -> ProfileScreen(
                    themeMode = themeMode,
                    onThemeChange = onThemeChange,
                    onOpenDetail = onOpenDetail,
                )
            }
        }
    }
}
