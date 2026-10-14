package com.cx.weibo.android.ui.compose

import android.widget.Toast
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.cx.weibo.android.data.WeiboService
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** 微博字数上限 */
private const val MAX_LEN = 2000

/**
 * 发微博（纯文字）。
 * 走 weibo.com 桌面端 `/ajax/statuses/update`（复用现有会话 + CSRF）。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposeScreen(
    onBack: () -> Unit,
    onPosted: (String) -> Unit,
) {
    val client = WeiboService.client
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var text by remember { mutableStateOf("") }
    var visible by remember { mutableIntStateOf(0) }
    var busy by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("发微博") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    TextButton(
                        enabled = !busy && text.isNotBlank(),
                        onClick = {
                            busy = true
                            scope.launch {
                                val r = withContext(Dispatchers.IO) {
                                    runCatching { client.postStatus(text, visible.toUInt()) }
                                }
                                busy = false
                                r.onSuccess {
                                    Toast.makeText(ctx, "已发布", Toast.LENGTH_SHORT).show()
                                    onPosted(it)
                                }.onFailure {
                                    Toast.makeText(ctx, "发布失败：${it.message}", Toast.LENGTH_LONG).show()
                                }
                            }
                        },
                    ) {
                        Text(if (busy) "发布中…" else "发布")
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(16.dp),
        ) {
            OutlinedTextField(
                value = text,
                onValueChange = { if (it.length <= MAX_LEN) text = it },
                placeholder = { Text("有什么新鲜事想分享给大家？") },
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            )

            Spacer(Modifier.height(10.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.horizontalScroll(rememberScrollState()),
            ) {
                Text(
                    "${text.length}/$MAX_LEN",
                    style = MaterialTheme.typography.labelSmall,
                    color = if (text.length > MAX_LEN - 100) MaterialTheme.colorScheme.error
                    else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.weight(1f))
                FilterChip(
                    selected = visible == 0,
                    onClick = { visible = 0 },
                    label = { Text("公开") },
                )
                FilterChip(
                    selected = visible == 1,
                    onClick = { visible = 1 },
                    label = { Text("仅关注") },
                )
                FilterChip(
                    selected = visible == 6,
                    onClick = { visible = 6 },
                    label = { Text("仅自己") },
                )
            }
        }
    }
}
