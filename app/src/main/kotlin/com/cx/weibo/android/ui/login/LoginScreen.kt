package com.cx.weibo.android.ui.login

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.cx.weibo.android.data.WeiboService
import com.cx.weibo.http.RawRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun LoginScreen(vm: LoginViewModel) {
    val state by vm.state.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("微博客户端", style = MaterialTheme.typography.headlineMedium)

        Spacer(Modifier.height(24.dp))

        when (val s = state) {
            LoginUiState.Checking -> StatusBlock("正在检查登录状态…")

            LoginUiState.LoadingQr -> StatusBlock("正在获取二维码…")

            is LoginUiState.ShowQr -> {
                QrImage(url = s.qr.imageUrl, size = 260.dp)
                Spacer(Modifier.height(16.dp))
                Text(s.hint, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)

                Spacer(Modifier.height(20.dp))
                ScanHelp()
            }

            LoginUiState.LoggedIn -> StatusBlock("已登录")

            is LoginUiState.Failed -> {
                Text(
                    s.message,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(16.dp))
                Button(onClick = { vm.retry() }) { Text("重新获取二维码") }
            }
        }
    }
}

@Composable
private fun StatusBlock(text: String) {
    CircularProgressIndicator()
    Spacer(Modifier.height(12.dp))
    Text(text, style = MaterialTheme.typography.bodyMedium)
}

/** 扫码登录说明 */
@Composable
private fun ScanHelp() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(14.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Text(
            "扫码登录说明",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        listOf(
            "1. 打开手机上的「微博」App",
            "2. 点右上角「+」→ 扫一扫",
            "3. 对准上面的二维码，或在相册里选这张图",
            "4. 在手机上点「确认登录」",
        ).forEach {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(vertical = 2.dp),
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            "提示：二维码约 3 分钟失效，过期后点下方按钮重新获取。",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.error,
        )
    }
}

/** 从 URL 拉取二维码 PNG 并解码显示（不引入图片库，一张图够用） */
@Composable
private fun QrImage(url: String, size: androidx.compose.ui.unit.Dp) {
    var bitmap by remember(url) { mutableStateOf<ImageBitmap?>(null) }

    LaunchedEffect(url) {
        bitmap = withContext(Dispatchers.IO) {
            runCatching {
                val resp = WeiboService.engine.execute(
                    RawRequest(url, "GET", mapOf("User-Agent" to "Mozilla/5.0"))
                )
                BitmapFactory.decodeByteArray(resp.body, 0, resp.body.size)?.asImageBitmap()
            }.getOrNull()
        }
    }

    val bmp = bitmap
    if (bmp != null) {
        Image(
            bitmap = bmp,
            contentDescription = "登录二维码",
            modifier = Modifier.size(size),
            contentScale = ContentScale.Fit,
        )
    } else {
        Box(modifier = Modifier.size(size), contentAlignment = Alignment.Center) {
            CircularProgressIndicator()
        }
    }
}
