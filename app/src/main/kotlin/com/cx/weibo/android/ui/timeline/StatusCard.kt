package com.cx.weibo.android.ui.timeline

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import com.cx.weibo.Status
import com.cx.weibo.android.ui.common.ImageViewerDialog


@Composable
fun StatusCard(
    status: Status,
    onClick: (() -> Unit)? = null,
    onOpenUser: ((String, String) -> Unit)? = null,
    onLike: (() -> Unit)? = null,
    onRepost: (() -> Unit)? = null,
    onComment: (() -> Unit)? = null,
    liked: Boolean = false,
    likeDelta: Int = 0,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 12.dp)
    ) {
        Header(status, onOpenUser)

        Spacer(Modifier.height(8.dp))
        Text(
            text = status.plainText,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 8,
            overflow = TextOverflow.Ellipsis,
        )

        val images = status.imageUrls
        var viewerAt by remember { mutableStateOf<Int?>(null) }
        if (images.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                images.take(9).forEachIndexed { idx, url ->
                    AsyncImage(
                        model = url,
                        contentDescription = null,
                        modifier = Modifier
                            .size(100.dp)
                            .clip(RoundedCornerShape(6.dp))
                            .background(MaterialTheme.colorScheme.surfaceVariant)
                            .clickable { viewerAt = idx },
                        contentScale = ContentScale.Crop,
                    )
                }
            }
        }

        viewerAt?.let { at ->
            ImageViewerDialog(
                urls = images,
                startIndex = at,
                onDismiss = { viewerAt = null },
            )
        }

        status.retweetedStatus?.let { rt ->
            Spacer(Modifier.height(8.dp))
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(6.dp))
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(8.dp)
            ) {
                Text(
                    text = "@" + (rt.user?.screenName ?: ""),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(2.dp))
                Text(
                    text = rt.plainText,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 4,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Metric("转发", status.repostsCount, onClick = onRepost)
            Metric("评论", status.commentsCount, onClick = onComment)
            Metric(
                label = "赞",
                n = (status.attitudesCount ?: 0) + likeDelta,
                onClick = onLike,
                highlight = liked,
            )
        }

        Spacer(Modifier.height(10.dp))
        HorizontalDivider()
    }
}

@Composable
private fun Header(status: Status, onOpenUser: ((String, String) -> Unit)?) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        AsyncImage(
            model = status.user?.avatar,
            contentDescription = null,
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .clickable(enabled = onOpenUser != null) {
                    status.user?.let { u ->
                        onOpenUser?.invoke(u.idstr ?: "", u.screenName ?: "")
                    }
                },
            contentScale = ContentScale.Crop,
        )
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                text = status.user?.screenName ?: "?",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                text = status.displayTime,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Metric(
    label: String,
    n: Int?,
    onClick: (() -> Unit)? = null,
    highlight: Boolean = false,
) {
    Text(
        text = "$label ${n ?: 0}",
        style = MaterialTheme.typography.labelSmall,
        color = if (highlight) MaterialTheme.colorScheme.primary
        else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier
            .then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
            .padding(horizontal = 6.dp, vertical = 6.dp),
    )
}
