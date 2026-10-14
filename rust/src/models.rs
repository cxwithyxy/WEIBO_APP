//! 微博数据模型（Rust 移植）
//!
//! 对应原 Kotlin 的 `WeiboCore.kt` 数据模型部分。
//! 同时派生 `serde`（JSON 解析，替代 Gson 的 `@SerializedName`）
//! 与 `uniffi::Record`（跨 FFI 传给 Kotlin）。

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;
use std::sync::LazyLock;

/// HTML 标签正则（对应 Kotlin `Regex("<[^>]+>")`）
static TAG_RE: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new("<[^>]+>").unwrap());

/// 把任意 JSON 值序列化成它的文本形式。
///
/// 用途：`isAd` 字段是**多态的**（实测有时 bool、有时数字、有时字符串），
/// 用一个具体类型承接会解析失败，所以统一转成文本，再按 Kotlin 的逻辑判定。
fn de_any_to_text<'de, D>(d: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.map(|x| x.to_string()))
}

fn ser_any_to_text<S>(v: &Option<String>, s: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    match v {
        Some(t) => s.serialize_str(t),
        None => s.serialize_none(),
    }
}

/// 宽松地把「标量」反序列化成 `String`。
///
/// 微博接口经常把**同一个字段时而给字符串、时而给数字**（实测 `max_id` 给的是
/// 数字，而 `max_id_str` 是字符串）。原 Kotlin 用 Gson——它会自动把数字强转成
/// String，所以从来没暴露；serde 是严格类型，数字给 `String` 会直接报错。
/// 这里显式做同样的兼容，保持与原实现一致的行为。
fn de_scalar_string<'de, D>(d: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.and_then(|x| match x {
        serde_json::Value::Null => None,
        serde_json::Value::String(s) => Some(s),
        serde_json::Value::Number(n) => Some(n.to_string()),
        serde_json::Value::Bool(b) => Some(b.to_string()),
        other => Some(other.to_string()),
    }))
}

// ------------------------------------------------------------------ 模型

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct User {
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub idstr: Option<String>,
    #[serde(default, rename = "screen_name")]
    pub screen_name: Option<String>,
    #[serde(default, rename = "profile_image_url")]
    pub avatar: Option<String>,
    #[serde(default, rename = "followers_count")]
    pub followers_count: Option<i64>,
    #[serde(default, rename = "friends_count")]
    pub friends_count: Option<i64>,
    #[serde(default, rename = "statuses_count")]
    pub statuses_count: Option<i64>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub verified: Option<bool>,
    #[serde(default)]
    pub location: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct PicUrl {
    #[serde(default)]
    pub url: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct PicInfo {
    #[serde(default)]
    pub thumbnail: Option<PicUrl>,
    #[serde(default)]
    pub bmiddle: Option<PicUrl>,
    #[serde(default)]
    pub large: Option<PicUrl>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct Status {
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub idstr: Option<String>,
    #[serde(default, rename = "created_at")]
    pub created_at: Option<String>,
    #[serde(default, rename = "text_raw")]
    pub text_raw: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default, rename = "reposts_count")]
    pub reposts_count: Option<i32>,
    #[serde(default, rename = "comments_count")]
    pub comments_count: Option<i32>,
    #[serde(default, rename = "attitudes_count")]
    pub attitudes_count: Option<i32>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub user: Option<User>,
    #[serde(default, rename = "pic_ids")]
    pub pic_ids: Option<Vec<String>>,
    #[serde(default, rename = "pic_infos")]
    pub pic_infos: Option<HashMap<String, PicInfo>>,
    #[serde(default, rename = "pic_num")]
    pub pic_num: Option<i32>,
    #[serde(default, rename = "retweeted_status")]
    pub retweeted_status: Option<Box<Status>>,
    /// 原始 JSON 文本（字段多态）；判定见 [`Status::is_ad_flag`]
    #[serde(
        default,
        rename = "isAd",
        deserialize_with = "de_any_to_text",
        serialize_with = "ser_any_to_text"
    )]
    pub is_ad: Option<String>,
    /// 服务端会截断长文；为 true 时需调 longtext 取全文
    #[serde(default, rename = "isLongText")]
    pub is_long_text: Option<bool>,
}

impl Status {
    /// 是否广告。对应 Kotlin `isAdFlag`：
    /// bool → 自身；number → 非 0；string → 可转数字则非 0，否则 "true"（忽略大小写）
    pub fn is_ad_flag(&self) -> bool {
        let Some(txt) = &self.is_ad else { return false };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(txt) else {
            return false;
        };
        match v {
            serde_json::Value::Bool(b) => b,
            serde_json::Value::Number(n) => n.as_i64().map(|i| i != 0).unwrap_or(false),
            serde_json::Value::String(s) => s
                .parse::<i64>()
                .map(|i| i != 0)
                .unwrap_or_else(|_| s.eq_ignore_ascii_case("true")),
            _ => false,
        }
    }

    /// 纯文本（优先 text_raw，其次剥离 HTML 标签）
    pub fn plain_text(&self) -> String {
        if let Some(t) = &self.text_raw {
            return t.clone();
        }
        match &self.text {
            Some(t) => TAG_RE.replace_all(t, "").to_string(),
            None => String::new(),
        }
    }

    /// 展示用时间 YYYY/MM/DD HH:mm:SS
    pub fn display_time(&self) -> String {
        crate::weibo_time_format(self.created_at.clone().unwrap_or_default())
    }

    /// 配图 URL（优先 bmiddle 中等尺寸）
    pub fn image_urls(&self) -> Vec<String> {
        let ids = self.pic_ids.clone().unwrap_or_default();
        ids.into_iter()
            .map(|id| {
                self.pic_infos
                    .as_ref()
                    .and_then(|m| m.get(&id))
                    .and_then(|p| {
                        p.bmiddle
                            .as_ref()
                            .and_then(|x| x.url.clone())
                            .or_else(|| p.thumbnail.as_ref().and_then(|x| x.url.clone()))
                            .or_else(|| p.large.as_ref().and_then(|x| x.url.clone()))
                    })
                    .unwrap_or_else(|| format!("https://wx1.sinaimg.cn/wap360/{id}.jpg"))
            })
            .collect()
    }
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct HotItem {
    #[serde(default)]
    pub word: Option<String>,
    #[serde(default)]
    pub num: Option<i64>,
    #[serde(default)]
    pub realpos: Option<i32>,
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct Comment {
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub idstr: Option<String>,
    #[serde(default, rename = "created_at")]
    pub created_at: Option<String>,
    #[serde(default, rename = "text_raw")]
    pub text_raw: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default, rename = "like_counts")]
    pub like_counts: Option<i32>,
    #[serde(default, rename = "floor_number")]
    pub floor_number: Option<i32>,
    #[serde(default, rename = "is_mblog_author")]
    pub is_author: Option<bool>,
    #[serde(default)]
    pub user: Option<User>,
    #[serde(default, rename = "reply_comment")]
    pub reply_comment: Option<Box<Comment>>,
}

impl Comment {
    pub fn plain_text(&self) -> String {
        if let Some(t) = &self.text_raw {
            return t.clone();
        }
        match &self.text {
            Some(t) => TAG_RE.replace_all(t, "").to_string(),
            None => String::new(),
        }
    }
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct CommentPage {
    pub comments: Vec<Comment>,
    pub next_max_id: Option<i64>,
    pub total_number: Option<i32>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct TimelinePage {
    pub statuses: Vec<Status>,
    pub next_cursor: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct TimelineRaw {
    pub raw: String,
    pub statuses: Vec<Status>,
    pub next_cursor: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize)]
pub struct HotBandItem {
    #[serde(default)]
    pub word: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub num: Option<i64>,
    #[serde(default)]
    pub rank: Option<i32>,
    #[serde(default)]
    pub realpos: Option<i32>,
    #[serde(default, rename = "label_name")]
    pub label_name: Option<String>,
    #[serde(default, rename = "icon_desc")]
    pub icon_desc: Option<String>,
}

// ------------------------------------------------------------------
// 内部响应信封（纯 serde，不跨 FFI）
// ------------------------------------------------------------------

#[derive(Debug, Default, Deserialize)]
pub(crate) struct TimelineResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub statuses: Option<Vec<Status>>,
    // ⚠ 这几个 id 字段服务端会给**数字**（max_id 尤其），必须宽松处理
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub since_id: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub max_id: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub since_id_str: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub max_id_str: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct MyBlogResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<MyBlogData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct MyBlogData {
    #[serde(default)]
    pub list: Option<Vec<Status>>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub since_id: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct ProfileInfoResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<ProfileInfoData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct ProfileInfoData {
    #[serde(default)]
    pub user: Option<User>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct HotResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<HotData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct HotData {
    #[serde(default)]
    pub realtime: Option<Vec<HotItem>>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct FollowResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<FollowData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct FollowData {
    #[serde(default)]
    pub follows: Option<FollowUsers>,
    #[serde(default, rename = "total_number")]
    pub total_number: Option<i32>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct FollowUsers {
    #[serde(default)]
    pub users: Option<Vec<User>>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct SearchResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub statuses: Option<Vec<Status>>,
    #[serde(default, rename = "total_number")]
    pub total_number: Option<i32>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct CommentsResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<Vec<Comment>>,
    #[serde(default, rename = "total_number")]
    pub total_number: Option<i32>,
    #[serde(default)]
    pub max_id: Option<i64>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct RepostResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<Vec<Status>>,
    #[serde(default, rename = "total_number")]
    pub total_number: Option<i32>,
    #[serde(default)]
    pub max_page: Option<i32>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct HotBandResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<HotBandData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct HotBandData {
    #[serde(default, rename = "band_list")]
    pub band_list: Option<Vec<HotBandItem>>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct LongTextResp {
    pub ok: Option<i32>,
    #[serde(default)]
    pub data: Option<LongTextData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct LongTextData {
    #[serde(default, rename = "longTextContent")]
    pub long_text_content: Option<String>,
    #[serde(default, rename = "longTextContent_raw")]
    pub long_text_content_raw: Option<String>,
}

// ------------------------------------------------------------------
// 跨 FFI 的辅助函数（Kotlin 侧调用）
// ------------------------------------------------------------------

#[uniffi::export]
pub fn weibo_status_plain_text(s: Status) -> String {
    s.plain_text()
}

#[uniffi::export]
pub fn weibo_status_display_time(s: Status) -> String {
    s.display_time()
}

#[uniffi::export]
pub fn weibo_status_is_ad(s: Status) -> bool {
    s.is_ad_flag()
}

#[uniffi::export]
pub fn weibo_status_image_urls(s: Status) -> Vec<String> {
    s.image_urls()
}

#[uniffi::export]
pub fn weibo_comment_plain_text(c: Comment) -> String {
    c.plain_text()
}

/// 剥离 HTML 标签（导出给 Kotlin 用）
#[uniffi::export]
pub fn weibo_strip_tags(s: String) -> String {
    TAG_RE.replace_all(&s, "").to_string()
}
