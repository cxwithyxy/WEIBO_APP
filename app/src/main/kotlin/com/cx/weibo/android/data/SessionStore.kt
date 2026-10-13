package com.cx.weibo.android.data

import android.content.Context
import java.io.File
import java.nio.file.Path

/** 会话 cookie 落盘位置（App 私有目录，不进备份、不入库） */
object SessionStore {
    fun cookieFile(context: Context): Path =
        File(context.filesDir, "cookies.tsv").toPath()
}
