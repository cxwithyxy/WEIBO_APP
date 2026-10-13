package com.cx.weibo

/** 微博图片 URL 工具 */
object WeiboImages {

    /**
     * 由缩略图 URL 推出大图 URL。
     * 微博 CDN 的尺寸段在路径里：/wap360/、/bmiddle/、/thumbnail/、/orj360/ …
     */
    fun large(url: String): String =
        url.replace("/wap360/", "/large/")
            .replace("/orj360/", "/large/")
            .replace("/bmiddle/", "/large/")
            .replace("/thumbnail/", "/large/")
            .replace("/small/", "/large/")
            .replace("/mw690/", "/large/")
}
