package com.cx.weibo.android

import android.app.Application
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.crossfade

/** 配好 Coil 的图片加载器（用于头像与微博配图） */
class App : Application(), SingletonImageLoader.Factory {

    override fun onCreate() {
        super.onCreate()
        // Rust 核心打包为 libweibo_core.so，Android 会把它解压到应用私有目录；
        // JNA 需要被明确告知去哪里加载（否则找不到符号库）。
        System.setProperty("jna.library.path", applicationInfo.nativeLibraryDir)
    }

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components { add(OkHttpNetworkFetcherFactory()) }
            .crossfade(true)
            .build()
}
