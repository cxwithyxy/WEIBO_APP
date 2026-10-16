//! 微博客户端核心 —— Rust 实现（方案 A PoC）
//!
//! 目标：把 Kotlin `core` 里平台无关的逻辑迁到 Rust，
//! 通过 UniFFI 自动生成 Kotlin 绑定供 Android App 调用。
//!
//! 本文件对应原 Kotlin 的：
//!  - `WeiboTime.kt`   → weibo_time_* 函数
//!  - `WeiboImages.kt` → weibo_image_large 函数

#[cfg(feature = "uniffi-ffi")]
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
#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_time_epoch(raw: String) -> i64 {
    parse(&raw).map(|dt| dt.timestamp_millis()).unwrap_or(i64::MIN)
}

/// 格式化为 `YYYY/MM/DD HH:mm:SS`（本地时区）；解析失败原样返回。
/// 对应 Kotlin `WeiboTime.format()`。
#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_time_format(raw: String) -> String {
    match parse(&raw) {
        Some(dt) => dt.with_timezone(&Local).format(OUT_FMT).to_string(),
        None => raw,
    }
}

/// 缩略图 URL → 大图 URL。
/// 对应 Kotlin `WeiboImages.large()`。
#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
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

    /// 评论配图：原先 `Comment` 结构里压根没有 pic_* 字段，
    /// “图片评论”在客户端里只显示文字、图直接丢了。
    #[test]
    fn comment_image_urls() {
        let pid = "0061aNvTly1ii3f81kwlej30xc104jw6";
        let raw = format!(
            r#"{{
                "idstr": "5354675488424851",
                "text": "带图评论",
                "pic_ids": ["{pid}"],
                "pic_infos": {{
                    "{pid}": {{
                        "thumbnail": {{"url": "https://wx1.sinaimg.cn/orj360/{pid}.jpg"}},
                        "bmiddle":   {{"url": "https://wx1.sinaimg.cn/bmiddle/{pid}.jpg"}},
                        "large":     {{"url": "https://wx1.sinaimg.cn/large/{pid}.jpg"}}
                    }}
                }},
                "pic_num": 1
            }}"#
        );
        let c: models::Comment = serde_json::from_str(&raw).unwrap();
        assert_eq!(c.pic_num, Some(1));
        let urls = c.image_urls();
        assert_eq!(urls.len(), 1);
        // 降级链的第一档是 bmiddle
        assert!(urls[0].contains("/bmiddle/"), "应优先 bmiddle，实际 {urls:?}");
    }

    /// `pic_infos` 缺失时不能丢图：按 id 拼 wap360 兜底（与微博本体同一套行为）。
    #[test]
    fn comment_image_fallback() {
        let c: models::Comment = serde_json::from_str(r#"{"pic_ids":["abc"]}"#).unwrap();
        assert_eq!(
            c.image_urls(),
            vec!["https://wx1.sinaimg.cn/wap360/abc.jpg".to_string()]
        );
    }
}
