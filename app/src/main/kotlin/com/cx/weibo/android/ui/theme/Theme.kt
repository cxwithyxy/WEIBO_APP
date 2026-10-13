package com.cx.weibo.android.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

enum class ThemeMode { SYSTEM, LIGHT, DARK }

/** 微博红 */
private val WeiboRed = Color(0xFFE6162D)

private val LightColors = lightColorScheme(
    primary = WeiboRed,
    onPrimary = Color.White,
    background = Color(0xFFF7F7F7),
    onBackground = Color(0xFF1A1A1A),
    surface = Color.White,
    onSurface = Color(0xFF1A1A1A),
    surfaceVariant = Color(0xFFEFEFEF),
    onSurfaceVariant = Color(0xFF6B6B6B),
    outline = Color(0xFFDDDDDD),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFFF6B7A),
    onPrimary = Color(0xFF3A0009),
    background = Color(0xFF101012),
    onBackground = Color(0xFFE6E6E6),
    surface = Color(0xFF1B1B1E),
    onSurface = Color(0xFFE6E6E6),
    surfaceVariant = Color(0xFF26262A),
    onSurfaceVariant = Color(0xFF9E9EA5),
    outline = Color(0xFF33333A),
    error = Color(0xFFFF7A85),
)

@Composable
fun WeiboTheme(mode: ThemeMode, content: @Composable () -> Unit) {
    val dark = when (mode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    MaterialTheme(
        colorScheme = if (dark) DarkColors else LightColors,
        content = content,
    )
}
