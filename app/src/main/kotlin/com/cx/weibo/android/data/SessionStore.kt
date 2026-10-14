package com.cx.weibo.android.data

import android.content.Context
import java.io.File

/** 会话 cookie 落盘位置（App 私有目录，不进备份、不入库） */
object SessionStore {
    /** Rust 侧接口收路径字符串（原 Kotlin 版是 java.nio.file.Path） */
    fun cookieFile(context: Context): String =
        File(context.filesDir, "cookies.tsv").absolutePath
}
