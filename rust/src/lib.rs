//! 微博客户端核心 —— Rust 实现（方案 A PoC）
//!
//! 目标：把 Kotlin `core` 里平台无关的逻辑迁到 Rust，
//! 通过 UniFFI 自动生成 Kotlin 绑定供 Android App 调用。
//!
//! 本文件对应原 Kotlin 的：
//!  - `WeiboTime.kt`   → weibo_time_* 函数
//!  - `WeiboImages.kt` → weibo_image_large 函数

uniffi::setup_scaffolding!();

pub mod auth;
pub mod client;
pub mod http;
pub mod models;
pub mod reqwest_engine;

use chrono::{DateTime, Local};

/// 微博服务端 `created_at` 的格式：`Tue Oct 13 15:21:43 +0800 2026`
const IN_FMT: &str = "%a %b %d %H:%M:%S %z %Y";
/// 输出格式：`2026/10/13 15:21:43`
const OUT_FMT: &str = "%Y/%m/%d %H:%M:%S";

/// 解析微博时间串。
/// 对应 Kotlin `WeiboTime.parse()`。
fn parse(raw: &str) -> Option<DateTime<chrono::FixedOffset>> {
    DateTime::parse_from_str(raw.trim(), IN_FMT).ok()
}

/// 排序用：越大越新；缺失/解析失败视为最旧（i64::MIN）。
/// 对应 Kotlin `WeiboTime.epoch()`。
#[uniffi::export]
pub fn weibo_time_epoch(raw: String) -> i64 {
    parse(&raw).map(|dt| dt.timestamp_millis()).unwrap_or(i64::MIN)
}

/// 格式化为 `YYYY/MM/DD HH:mm:SS`（本地时区）；解析失败原样返回。
/// 对应 Kotlin `WeiboTime.format()`。
#[uniffi::export]
pub fn weibo_time_format(raw: String) -> String {
    match parse(&raw) {
        Some(dt) => dt.with_timezone(&Local).format(OUT_FMT).to_string(),
        None => raw,
    }
}

/// 缩略图 URL → 大图 URL。
/// 对应 Kotlin `WeiboImages.large()`。
#[uniffi::export]
pub fn weibo_image_large(url: String) -> String {
    let mut s = url;
    for (from, to) in [
        ("/wap360/", "/large/"),
        ("/orj360/", "/large/"),
        ("/bmiddle/", "/large/"),
        ("/thumbnail/", "/large/"),
        ("/small/", "/large/"),
        ("/mw690/", "/large/"),
    ] {
        s = s.replace(from, to);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_parse_ok() {
        let raw = "Tue Oct 13 15:21:43 +0800 2026";
        assert_eq!(weibo_time_format(raw.to_string()), "2026/10/13 15:21:43");
        assert!(weibo_time_epoch(raw.to_string()) > 0);
    }

    #[test]
    fn time_parse_bad_returns_input() {
        assert_eq!(weibo_time_format("garbage".into()), "garbage");
        assert_eq!(weibo_time_epoch("garbage".into()), i64::MIN);
    }

    #[test]
    fn image_upgrade() {
        assert_eq!(
            weibo_image_large("https://wx1.sinaimg.cn/wap360/abc.jpg".into()),
            "https://wx1.sinaimg.cn/large/abc.jpg"
        );
        assert_eq!(
            weibo_image_large("https://wx1.sinaimg.cn/mw690/abc.jpg".into()),
            "https://wx1.sinaimg.cn/large/abc.jpg"
        );
    }
}
