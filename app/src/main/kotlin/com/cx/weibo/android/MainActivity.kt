package com.cx.weibo.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cx.weibo.android.ui.MainTabs
import com.cx.weibo.android.ui.detail.StatusDetailScreen
import com.cx.weibo.android.ui.login.LoginScreen
import com.cx.weibo.android.ui.login.LoginUiState
import com.cx.weibo.android.ui.login.LoginViewModel

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    AppRoot()
                }
            }
        }
    }
}

@Composable
private fun AppRoot() {
    val loginVm: LoginViewModel = viewModel()
    val state by loginVm.state.collectAsStateWithLifecycle()

    if (state !is LoginUiState.LoggedIn) {
        LoginScreen(loginVm)
        return
    }

    // 极简导航：详情页作为覆盖层，其余交给底部导航
    var detailMid by remember { mutableStateOf<String?>(null) }
    val mid = detailMid
    if (mid != null) {
        StatusDetailScreen(
            mid = mid,
            onBack = { detailMid = null },
            onOpenDetail = { detailMid = it },
        )
    } else {
        MainTabs(onOpenDetail = { detailMid = it })
    }
}
