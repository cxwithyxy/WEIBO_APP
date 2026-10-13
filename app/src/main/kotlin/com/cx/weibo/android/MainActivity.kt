package com.cx.weibo.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.cx.weibo.android.ui.login.LoginScreen
import com.cx.weibo.android.ui.login.LoginUiState
import com.cx.weibo.android.ui.login.LoginViewModel
import com.cx.weibo.android.ui.timeline.TimelineScreen
import com.cx.weibo.android.ui.timeline.TimelineViewModel

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

    if (state is LoginUiState.LoggedIn) {
        val timelineVm: TimelineViewModel = viewModel()
        TimelineScreen(timelineVm)
    } else {
        LoginScreen(loginVm)
    }
}
