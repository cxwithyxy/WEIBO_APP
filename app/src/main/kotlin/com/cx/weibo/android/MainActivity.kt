package com.cx.weibo.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cx.weibo.android.data.Prefs
import com.cx.weibo.android.ui.MainTabs
import com.cx.weibo.android.ui.detail.StatusDetailScreen
import com.cx.weibo.android.ui.login.LoginScreen
import com.cx.weibo.android.ui.login.LoginUiState
import com.cx.weibo.android.ui.login.LoginViewModel
import com.cx.weibo.android.ui.theme.ThemeMode
import com.cx.weibo.android.ui.theme.WeiboTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val activity = this
        setContent {
            val ctx = LocalContext.current
            var themeMode by remember { mutableStateOf(Prefs.themeMode(ctx)) }

            WeiboTheme(ThemeMode.valueOf(themeMode)) {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AppRoot(
                        themeMode = themeMode,
                        onThemeChange = {
                            Prefs.setThemeMode(ctx, it)
                            themeMode = it
                        },
                        onExit = { activity.finish() },
                    )
                }
            }
        }
    }
}

@Composable
private fun AppRoot(
    themeMode: String,
    onThemeChange: (String) -> Unit,
    onExit: () -> Unit,
) {
    val loginVm: LoginViewModel = viewModel()
    val state by loginVm.state.collectAsStateWithLifecycle()

    if (state !is LoginUiState.LoggedIn) {
        LoginScreen(loginVm)
        return
    }

    var detailMid by remember { mutableStateOf<String?>(null) }
    val mid = detailMid

    // 关键：详情页用**覆盖**而不是替换 —— 否则 MainTabs 会被销毁重建，
    // LazyListState 丢失，返回列表就跳到顶部了。
    Box(Modifier.fillMaxSize()) {
        MainTabs(
            themeMode = themeMode,
            onThemeChange = onThemeChange,
            onExit = onExit,
            onOpenDetail = { detailMid = it },
        )

        if (mid != null) {
            Surface(Modifier.fillMaxSize()) {
                StatusDetailScreen(
                    mid = mid,
                    onBack = { detailMid = null },
                    onOpenDetail = { detailMid = it },
                )
            }
        }
    }

    // 注册在 MainTabs 之后 → 优先生效，先关详情
    BackHandler(enabled = mid != null) { detailMid = null }
}
