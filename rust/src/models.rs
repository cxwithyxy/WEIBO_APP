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

/// 表情图标签：`<img alt="[微笑]" title="[微笑]" src="..."/>`。
///
/// 微博的正文/评论里表情**不是文字**，而是一个 `<img>`，文字只在 `alt` 里。
/// 「直接把标签剥掉」会把表情整个删掉 —— 纯表情评论（实测「我的评论」
/// 第一条就只有一个 `[微笑]`）会渲染成**空白**。
static EMOJI_IMG_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r"<img\b[^>]*>").unwrap());

static ALT_ATTR_RE: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new(r#"alt="([^"]*)""#).unwrap());

/// 微博 HTML 正文 → 纯文本：表情取 `alt`，其余标签剥掉，再还原常见实体。
///
/// 顺序很重要：**先取表情的 alt**，再剥标签；反过来 alt 就没了。
pub fn html_to_text(html: &str) -> String {
    // 表情：把整段 `<img ...>` 换成它的 `alt`（`[微笑]` 这种）。
    // 注意必须匹配**整个标签**：只匹配到 `<img alt="x"` 的话，剩下的
    // ` src=.../>` 已经不含 `<`，后面的 TAG_RE 就剥不掉，会漏进正文。
    let with_emoji = EMOJI_IMG_RE.replace_all(html, |caps: &regex::Captures| {
        ALT_ATTR_RE
            .captures(&caps[0])
            .map(|c| c[1].to_string())
            .unwrap_or_default()
    });
    let stripped = TAG_RE.replace_all(&with_emoji, "");
    stripped
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .trim()
        .to_string()
}

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

/// 宽松地把「标量」反序列化成 `f64`（同为微博接口的字符串/数字混用问题）。
fn de_scalar_f64<'de, D>(d: D) -> Result<Option<f64>, D::Error>
where
    D: Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.and_then(|x| match x {
        serde_json::Value::Number(n) => n.as_f64(),
        serde_json::Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }))
}

/// 宽松地把「标量」反序列化成 `i64`。
fn de_scalar_i64<'de, D>(d: D) -> Result<Option<i64>, D::Error>
where
    D: Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(d)?;
    Ok(v.and_then(|x| match x {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::String(s) => s
            .trim()
            .parse::<i64>()
            .ok()
            .or_else(|| s.trim().parse::<f64>().ok().map(|f| f as i64)),
        _ => None,
    }))
}

/// `None` / 空串 / 纯空白都视为「没有值」。
///
/// 实测 `media_info` 里缺失的档位经常以**空字符串**下发（不是缺字段、也不是 null），
/// 例如 `"h265_mp4_hd": ""`；不做这层归一化会把空 URL 当成有效视频地址。
fn nonempty(s: Option<&str>) -> Option<&str> {
    s.map(str::trim).filter(|s| !s.is_empty())
}

/// 粗略判断一个字符串是不是**视频**直链。
///
/// 不能只看字段名：`playback_list` 里除了视频，还会混进 `scrubber_hd` 之类的
/// **图片**条目（`image/jpeg`，实测 url 形如 `https://wx4.sinaimg.cn/large/xxx.jpg`）。
/// 优先看扩展名/mime，明确排除图片后缀。
fn looks_like_video_url(u: &str) -> bool {
    let l = u.to_ascii_lowercase();
    if l.contains(".jpg") || l.contains(".jpeg") || l.contains(".png") || l.contains(".gif") {
        return false;
    }
    l.contains(".mp4") || l.contains("video/mp4") || l.contains("weibocdn.com")
}

// ------------------------------------------------------------------ 模型

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PicUrl {
    #[serde(default)]
    pub url: Option<String>,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PicInfo {
    #[serde(default)]
    pub thumbnail: Option<PicUrl>,
    #[serde(default)]
    pub bmiddle: Option<PicUrl>,
    #[serde(default)]
    pub large: Option<PicUrl>,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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
    /// 当前登录用户是否点过赞。微博的时间线与 `statuses/show` 都用这个字段
    /// （`0`/`1`），与 `attitudes_count`（总赞数）是两回事。缺省视为未点赞。
    #[serde(default, rename = "attitudes_status")]
    pub attitudes_status: Option<i32>,
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
    /// 卡片信息原文（多态对象，视频/网页/文章…形状各不相同）。
    ///
    /// 与 `is_ad` 同一套思路：**存原始 JSON 文本**，而不是直接塞一个具体结构。
    /// 这样既不挑形状（缺字段/多字段都不会解析失败），又能把原文原样打印出来
    /// 和模型解析结果对照。需要类型化视图时调 [`Status::page_info_parsed`]。
    ///
    /// ⚠️ 真数据实测：视频卡片的 `type` 是字符串 `"11"`，`object_type` 才是
    /// `"video"`（与文档里「type == video」的预期不一致）。判定见
    /// [`PageInfo::is_video`]。
    #[serde(
        default,
        rename = "page_info",
        deserialize_with = "de_any_to_text",
        serialize_with = "ser_any_to_text"
    )]
    pub page_info: Option<String>,
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

    /// 当前登录用户是否已点赞（服务端真值，来自 `attitudes_status`）。
    ///
    /// UI 的点赞图标必须用它初始化，不能写死 false，否则冷启动后即使服务端
    /// 已点赞也会显示成灰色（`statuses/show` 与时间线都返回这个字段）。
    pub fn is_liked(&self) -> bool {
        self.attitudes_status.map(|v| v > 0).unwrap_or(false)
    }

    /// 纯文本（优先 text_raw，其次剥离 HTML 标签）
    pub fn plain_text(&self) -> String {
        if let Some(t) = &self.text_raw {
            if !t.is_empty() {
                return t.clone();
            }
        }
        match &self.text {
            Some(t) => html_to_text(t),
            None => String::new(),
        }
    }

    /// 展示用时间 YYYY/MM/DD HH:mm:SS
    pub fn display_time(&self) -> String {
        crate::weibo_time_format(self.created_at.clone().unwrap_or_default())
    }

    /// 配图 URL（优先 bmiddle 中等尺寸）
    pub fn image_urls(&self) -> Vec<String> {
        pic_urls(&self.pic_ids, &self.pic_infos)
    }

    // ---------------- 视频（page_info） ----------------

    /// 把存下来的 `page_info` 原文解析成类型化结构；缺失/解析失败返回 `None`。
    pub fn page_info_parsed(&self) -> Option<PageInfo> {
        let raw = self.page_info.as_ref()?;
        serde_json::from_str::<PageInfo>(raw).ok()
    }

    /// 本条微博（含其转发块）是否带视频。
    ///
    /// 判定以 `page_info` 的**类型字段**为准（见 [`PageInfo::is_video`]），
    /// 不会把普通网页链接卡片误判成视频。
    pub fn is_video(&self) -> bool {
        self.video_source().is_some()
    }

    /// 选出「哪一段 `page_info` 是视频」。
    ///
    /// **转发策略：计入。** 理由：转发的常见形态是「外层只有转发文字，视频挂在
    /// `retweeted_status.page_info`」，如果只看外层，转发视频会整条丢失。优先级上
    /// **本条优先**：只有本条不是视频时，才回退到被转发微博的视频；回退时返回
    /// `true` 表示来源是转发块（URL 的 source 标签会带 `retweeted_status.` 前缀）。
    ///
    /// 评论（`Comment`）**不在此列**：`buildComments` 的评论对象只有 `pic_*`
    /// 图片字段，没有 `page_info`；真实接口里也没见过评论视频，故本次不给
    /// `Comment` 加视频建模（若以后出现再加）。
    fn video_source(&self) -> Option<(PageInfo, bool)> {
        if let Some(p) = self.page_info_parsed() {
            if p.is_video() {
                return Some((p, false));
            }
        }
        let rt = self.retweeted_status.as_ref()?;
        let p = rt.page_info_parsed()?;
        if p.is_video() {
            Some((p, true))
        } else {
            None
        }
    }

    /// 最佳视频直链（按 [`PageInfo::video_url_with_source`] 的优先级）。
    pub fn video_url(&self) -> Option<String> {
        self.video_url_with_source().map(|(u, _)| u)
    }

    /// 同 [`Status::video_url`]，但同时给出**这个 URL 来自哪个字段**，
    /// 方便 CLI 打印出处、也方便和原始 JSON 逐字核对。
    pub fn video_url_with_source(&self) -> Option<(String, String)> {
        let (p, from_rt) = self.video_source()?;
        let (u, src) = p.video_url_with_source()?;
        let src = if from_rt {
            format!("retweeted_status.{src}")
        } else {
            src
        };
        Some((u, src))
    }

    /// 视频封面（`page_pic` 优先，其次 `pic_info.pic_big/pic_small`）。
    pub fn video_cover_url(&self) -> Option<String> {
        self.video_source().and_then(|(p, _)| p.cover_url())
    }

    /// 视频时长（秒）。优先 `media_info.duration`，缺失时退回播放列表里的时长。
    pub fn video_duration(&self) -> Option<i64> {
        self.video_source().and_then(|(p, _)| p.duration_secs())
    }
}

// ------------------------------------------------------------------
// 视频 / 卡片：page_info 的类型化视图
// ------------------------------------------------------------------
//
// 这些结构**全部字段 Option + `#[serde(default)]`**，缺字段/多字段都不报错，
// 只求把真实响应里我们关心的部分捞出来。
//
// ⚠️ 这里刻意**不派生 `uniffi::Record`**：`urls` / `pic_info` 用了
// `serde_json::Value`（跨 FFI 不安全），而且本次交付不碰桥接层。`Status` 本身
// 仍只存字符串，因此 FFI 形状不变。

/// `page_info`：微博卡片/视频信息。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PageInfo {
    /// 实测视频卡片给的是字符串 `"11"`（不是 `"video"`）。
    #[serde(default, rename = "type", deserialize_with = "de_scalar_string")]
    pub page_type: Option<String>,
    /// 实测视频卡片为 `"video"`；网页卡片一般是 `"webpage"`。
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub object_type: Option<String>,
    #[serde(default)]
    pub page_title: Option<String>,
    /// 封面图。
    #[serde(default)]
    pub page_pic: Option<String>,
    /// 卡片落地页（`sinaweibo://…` 或 https）。**不是**视频直链。
    #[serde(default)]
    pub page_url: Option<String>,
    #[serde(default)]
    pub media_info: Option<MediaInfo>,
    /// 部分响应会在这里再给一份 mp4 地址（键名不固定），形状未知 → 存原始值。
    #[serde(default)]
    pub urls: Option<serde_json::Value>,
    /// 封面/竖图信息（`pic_big` / `pic_small`）→ 存原始值。
    #[serde(default)]
    pub pic_info: Option<serde_json::Value>,
}

impl PageInfo {
    /// 是否视频卡片。
    ///
    /// 真数据里 `object_type == "video"`、`type == "11"`。**不能只看 `type`**：
    /// 普通网页链接卡片也可能带数字 type。这里做三级判定：
    /// 1. `object_type == "video"` → 视频；
    /// 2. `type == "video"`（少数接口的写法）→ 视频；
    /// 3. `type == "11"` **且 `media_info` 里确有视频直链** → 视频。
    ///
    /// 这样「type=11 但没有 media_info / 只有图片」的卡片不会被误判。
    pub fn is_video(&self) -> bool {
        if self.object_type.as_deref() == Some("video") {
            return true;
        }
        if self.page_type.as_deref() == Some("video") {
            return true;
        }
        if self.page_type.as_deref() == Some("11") {
            return self.media_info.as_ref().map(MediaInfo::has_video).unwrap_or(false);
        }
        false
    }

    /// 视频直链 + 字段出处（用于 CLI 打印与逐字核对）。
    ///
    /// 优先级（以真数据实测到的字段为准，空档自然跳过）：
    /// `media_info.mp4_720p_mp4` → `mp4_hd_url` → `mp4_sd_url` → `stream_url`
    /// → `stream_url_hd` → `playback_list[].play_info.url` → `urls.*`。
    /// 返回的 URL **原样透传**，不做任何解码/改写。
    pub fn video_url_with_source(&self) -> Option<(String, String)> {
        if let Some(mi) = &self.media_info {
            if let Some(x) = mi.best_url_with_source() {
                return Some(x);
            }
        }
        url_from_urls(self.urls.as_ref())
    }

    /// 封面：`page_pic` 优先，其次 `pic_info.pic_big` / `pic_info.pic_small` 的 url。
    pub fn cover_url(&self) -> Option<String> {
        if let Some(u) = nonempty(self.page_pic.as_deref()) {
            return Some(u.to_string());
        }
        let pi = self.pic_info.as_ref()?;
        for key in ["pic_big", "pic_small"] {
            if let Some(u) = pi.get(key).and_then(|x| x.get("url")).and_then(|x| x.as_str()) {
                if !u.trim().is_empty() {
                    return Some(u.to_string());
                }
            }
        }
        None
    }

    /// 时长（秒）：优先顶层 `media_info.duration`，缺失时退回播放列表里第一条时长。
    pub fn duration_secs(&self) -> Option<i64> {
        let mi = self.media_info.as_ref()?;
        if let Some(d) = mi.duration {
            return Some(d.round() as i64);
        }
        mi.playback_list
            .as_ref()?
            .iter()
            .filter_map(|it| it.play_info.as_ref()?.duration)
            .next()
            .map(|d| d.round() as i64)
    }
}

/// `page_info.media_info`：视频的地址、时长、多档播放列表。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MediaInfo {
    /// 秒。实测顶层是整数，播放列表里是浮点，故用 f64 兜。
    #[serde(default, deserialize_with = "de_scalar_f64")]
    pub duration: Option<f64>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub mp4_720p_mp4: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub mp4_hd_url: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub mp4_sd_url: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub stream_url: Option<String>,
    /// 真数据里存在但任务清单没列的 HD 流地址；作为 `stream_url` 之后的补充档。
    #[serde(default, deserialize_with = "de_scalar_string")]
    pub stream_url_hd: Option<String>,
    #[serde(default)]
    pub playback_list: Option<Vec<PlaybackItem>>,
}

impl MediaInfo {
    /// `media_info` 里是否有可用的视频直链（供 `is_video` 兜底判定）。
    pub fn has_video(&self) -> bool {
        [
            &self.mp4_720p_mp4,
            &self.mp4_hd_url,
            &self.mp4_sd_url,
            &self.stream_url,
            &self.stream_url_hd,
        ]
        .iter()
        .any(|v| nonempty(v.as_deref()).is_some())
            || self.playback_list.as_ref().is_some_and(|pl| {
                pl.iter().any(|it| {
                    it.play_info
                        .as_ref()
                        .map(|p| p.is_video() && nonempty(p.url.as_deref()).is_some())
                        .unwrap_or(false)
                })
            })
    }

    /// 直链优先级：顶层单档字段 → `playback_list`（取分辨率最高的视频档）。
    pub fn best_url_with_source(&self) -> Option<(String, String)> {
        for (name, val) in [
            ("media_info.mp4_720p_mp4", &self.mp4_720p_mp4),
            ("media_info.mp4_hd_url", &self.mp4_hd_url),
            ("media_info.mp4_sd_url", &self.mp4_sd_url),
            ("media_info.stream_url", &self.stream_url),
            ("media_info.stream_url_hd", &self.stream_url_hd),
        ] {
            if let Some(u) = nonempty(val.as_deref()) {
                return Some((u.to_string(), name.to_string()));
            }
        }
        let pl = self.playback_list.as_ref()?;
        let mut best: Option<(&PlaybackInfo, String)> = None;
        let mut best_h = i64::MIN;
        for it in pl {
            let Some(pi) = &it.play_info else { continue };
            if !pi.is_video() || nonempty(pi.url.as_deref()).is_none() {
                continue;
            }
            let label = it
                .meta
                .as_ref()
                .and_then(|m| m.label.clone())
                .unwrap_or_else(|| "?".to_string());
            let h = pi.height.unwrap_or(0);
            if best.is_none() || h > best_h {
                best = Some((pi, label));
                best_h = h;
            }
        }
        let (pi, label) = best?;
        let u = nonempty(pi.url.as_deref())?;
        Some((
            u.to_string(),
            format!("media_info.playback_list[{label}].play_info.url"),
        ))
    }
}

/// `media_info.playback_list[]` 的一项。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PlaybackItem {
    #[serde(default)]
    pub meta: Option<PlaybackMeta>,
    #[serde(default)]
    pub play_info: Option<PlaybackInfo>,
}

/// 播放项的 `meta`（人类可读的档位标签）。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PlaybackMeta {
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub quality_label: Option<String>,
    #[serde(default)]
    pub quality_desc: Option<String>,
}

/// 播放项的 `play_info`（真正带 url / mime / 分辨率）。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PlaybackInfo {
    /// 实测 1=视频、3=图片（scrubber）。仅作参考，判定主要看 `mime`/后缀。
    #[serde(default, deserialize_with = "de_scalar_i64")]
    pub r#type: Option<i64>,
    #[serde(default)]
    pub mime: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default, deserialize_with = "de_scalar_i64")]
    pub height: Option<i64>,
    #[serde(default, deserialize_with = "de_scalar_i64")]
    pub width: Option<i64>,
    #[serde(default, deserialize_with = "de_scalar_f64")]
    pub duration: Option<f64>,
}

impl PlaybackInfo {
    /// 是否视频条目：`mime` 以 `video/` 开头，或 url 像视频直链。
    /// 这样能挡掉同为 `playback_list` 成员的 `scrubber_hd`（`image/jpeg`）。
    pub fn is_video(&self) -> bool {
        if let Some(m) = self.mime.as_deref() {
            if m.to_ascii_lowercase().starts_with("video/") {
                return true;
            }
        }
        nonempty(self.url.as_deref())
            .map(looks_like_video_url)
            .unwrap_or(false)
    }
}

/// 从 `page_info.urls`（键名不固定的对象）里挑视频直链。
///
/// 先按已知键名试，再退化为「任意一个像视频直链的字符串值」。
fn url_from_urls(v: Option<&serde_json::Value>) -> Option<(String, String)> {
    let v = v?;
    for key in [
        "mp4_720p_mp4",
        "mp4_hd_mp4",
        "mp4_hd_url",
        "mp4_sd_url",
        "mp4_sd_mp4",
        "stream_url",
        "stream_url_hd",
    ] {
        if let Some(s) = v.get(key).and_then(|x| x.as_str()) {
            if !s.trim().is_empty() {
                return Some((s.to_string(), format!("urls.{key}")));
            }
        }
    }
    let obj = v.as_object()?;
    for (k, val) in obj {
        if let Some(s) = val.as_str() {
            if !s.trim().is_empty() && looks_like_video_url(s) {
                return Some((s.to_string(), format!("urls.{k}")));
            }
        }
    }
    None
}

/// `pic_ids` + `pic_infos` → 可直接加载的 URL 列表。
///
/// **微博与评论共用**：评论的图片字段形状和微博完全一样（`pic_ids` 给顺序，
/// `pic_infos` 是按 id 索引的字典），所以抽成一个函数，避免两处各写一份
/// 「取 bmiddle → 退 thumbnail → 退 large → 兜底拼 wap360」的降级链。
pub(crate) fn pic_urls(
    pic_ids: &Option<Vec<String>>,
    pic_infos: &Option<HashMap<String, PicInfo>>,
) -> Vec<String> {
    pic_ids
        .clone()
        .unwrap_or_default()
        .into_iter()
        .map(|id| {
            pic_infos
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

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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
    /// 评论配图 —— 字段形状与 `Status` 一致（原先缺这三个字段，
    /// 导致「图片评论」在客户端里只显示文字，图直接丢了）。
    #[serde(default, rename = "pic_ids")]
    pub pic_ids: Option<Vec<String>>,
    #[serde(default, rename = "pic_infos")]
    pub pic_infos: Option<HashMap<String, PicInfo>>,
    #[serde(default, rename = "pic_num")]
    pub pic_num: Option<i32>,
    /// 被评论的**原微博** —— 只有「我的评论」(`/ajax/message/myCmt`) 会带；
    /// `buildComments` 不带（那里原微博是调用方已知的）。
    /// 用 `Box` 避免 `Comment` ↔ `Status` 之间因 `retweeted_status` 撑出无限大小。
    #[serde(default)]
    pub status: Option<Box<Status>>,
}

impl Comment {
    /// 评论配图 URL 列表（复用 `Status` 的同一套还原逻辑）。
    pub fn image_urls(&self) -> Vec<String> {
        pic_urls(&self.pic_ids, &self.pic_infos)
    }

    pub fn plain_text(&self) -> String {
        // ⚠️「我的评论」(`/ajax/message/myCmt`) 的 `text_raw` **是空字符串**，
        // 内容全在 HTML 的 `text` 里；这里必须回落到 `text`，否则整条评论空白。
        if let Some(t) = &self.text_raw {
            if !t.is_empty() {
                return t.clone();
            }
        }
        match &self.text {
            Some(t) => html_to_text(t),
            None => String::new(),
        }
    }
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct CommentPage {
    pub comments: Vec<Comment>,
    pub next_max_id: Option<i64>,
    pub total_number: Option<i32>,
}

/// 「我的评论」（`/ajax/message/myCmt`）一页。
///
/// 翻页游标是 `next_cursor`（**数字**，原样回传当 `max_id` 用），
/// 与 `buildComments` 的 `max_id` 是两套独立游标，别混用。
#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct MyCommentsPage {
    pub comments: Vec<Comment>,
    pub next_cursor: Option<i64>,
    pub total_number: Option<i32>,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TimelinePage {
    pub statuses: Vec<Status>,
    pub next_cursor: Option<String>,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct TimelineRaw {
    pub raw: String,
    pub statuses: Vec<Status>,
    pub next_cursor: Option<String>,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
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

/// `/ajax/message/myCmt` 响应：`data` 是一个对象（不是数组）。
#[derive(Debug, Default, Deserialize)]
pub(crate) struct MyCommentsResp {
    pub ok: Option<i32>,
    pub message: Option<String>,
    #[serde(default)]
    pub data: Option<MyCommentsData>,
}

#[derive(Debug, Default, Deserialize)]
pub(crate) struct MyCommentsData {
    #[serde(default)]
    pub comments: Vec<Comment>,
    /// 翻页游标；实测是**数字**，但也可能被返回成字符串，故用宽松解析。
    #[serde(default, deserialize_with = "de_scalar_i64")]
    pub next_cursor: Option<i64>,
    #[serde(default, rename = "total_number")]
    pub total_number: Option<i32>,
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

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_status_plain_text(s: Status) -> String {
    s.plain_text()
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_status_display_time(s: Status) -> String {
    s.display_time()
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_status_is_ad(s: Status) -> bool {
    s.is_ad_flag()
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_status_image_urls(s: Status) -> Vec<String> {
    s.image_urls()
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_comment_plain_text(c: Comment) -> String {
    c.plain_text()
}

/// 剥离 HTML 标签（导出给 Kotlin 用）
#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_strip_tags(s: String) -> String {
    TAG_RE.replace_all(&s, "").to_string()
}

// ------------------------------------------------------------------
// 视频提取单测（合成夹具）
// ------------------------------------------------------------------

#[cfg(test)]
mod video_tests {
    use super::Status;

    fn parse(raw: &str) -> Status {
        serde_json::from_str(raw).expect("fixture 应能被宽松解析")
    }

    /// ① `media_info.mp4_720p_mp4` 有值：取最高优先级那一档，且 URL 原样。
    #[test]
    fn video_prefers_720p_mp4() {
        let raw = r#"{
            "idstr": "1",
            "page_info": {
                "type": "11",
                "object_type": "video",
                "page_title": "标题",
                "page_pic": "https://wx1.sinaimg.cn/orj480/cover.jpg",
                "media_info": {
                    "duration": 75,
                    "mp4_720p_mp4": "https://f.video.weibocdn.com/720.mp4?a=1&b=2",
                    "mp4_hd_url": "https://f.video.weibocdn.com/hd.mp4",
                    "mp4_sd_url": "https://f.video.weibocdn.com/sd.mp4",
                    "stream_url": "https://f.video.weibocdn.com/stream.mp4"
                }
            }
        }"#;
        let s = parse(raw);
        assert!(s.is_video());
        let (url, src) = s.video_url_with_source().unwrap();
        assert_eq!(url, "https://f.video.weibocdn.com/720.mp4?a=1&b=2");
        assert!(src.contains("mp4_720p_mp4"), "source={src}");
        assert_eq!(s.video_duration(), Some(75));
        assert_eq!(
            s.video_cover_url().as_deref(),
            Some("https://wx1.sinaimg.cn/orj480/cover.jpg")
        );
        // URL 必须能在存下来的 page_info 原文里逐字找到
        assert!(s.page_info.as_deref().unwrap().contains(&url));
    }

    /// ② 顶层单档字段全空，只有 `playback_list`：选视频档、跳过 scrubber 图片档，
    ///    并在多个视频档里取分辨率最高者。
    #[test]
    fn video_from_playback_list_skips_scrubber_image() {
        let raw = r#"{
            "idstr": "2",
            "page_info": {
                "type": "11",
                "object_type": "video",
                "media_info": {
                    "duration": 30,
                    "mp4_720p_mp4": "",
                    "mp4_hd_url": "   ",
                    "stream_url": null,
                    "playback_list": [
                        {"meta": {"label": "scrubber_hd", "type": 3},
                         "play_info": {"type": 3, "mime": "image/jpeg", "height": 180,
                                       "url": "https://wx4.sinaimg.cn/large/scrubber.jpg"}},
                        {"meta": {"label": "mp4_hd"},
                         "play_info": {"type": 1, "mime": "video/mp4", "height": 480,
                                       "url": "https://f.video.weibocdn.com/480.mp4"}},
                        {"meta": {"label": "mp4_720p"},
                         "play_info": {"type": 1, "mime": "video/mp4", "height": 720,
                                       "url": "https://f.video.weibocdn.com/720.mp4"}}
                    ]
                }
            }
        }"#;
        let s = parse(raw);
        assert!(s.is_video());
        let (url, src) = s.video_url_with_source().unwrap();
        assert_eq!(url, "https://f.video.weibocdn.com/720.mp4", "应取最高的 720 档");
        assert!(src.contains("playback_list") && src.contains("mp4_720p"), "source={src}");
        assert!(!url.ends_with(".jpg"), "绝不能把 scrubber 图片当视频");
    }

    /// ③ 网页/普通链接卡片，以及「type=11 但没有 media_info」→ 判为无视频。
    #[test]
    fn non_video_card_is_not_video() {
        let webpage = parse(
            r#"{"idstr":"3","page_info":{"type":"webpage","object_type":"webpage",
                "page_title":"某网页","page_url":"https://example.com/a"}}"#,
        );
        assert!(!webpage.is_video());
        assert_eq!(webpage.video_url(), None);
        assert_eq!(webpage.video_cover_url(), None);
        assert_eq!(webpage.video_duration(), None);

        // type=11 但没有任何视频字段：不能凭 type 就误判
        let empty11 = parse(r#"{"idstr":"4","page_info":{"type":"11","media_info":{}}}"#);
        assert!(!empty11.is_video());
        assert_eq!(empty11.video_url(), None);
    }

    /// ④ 视频在转发块 `retweeted_status.page_info` 里 → 计入，且来源带前缀。
    ///    若外层自己也有视频，则应优先外层。
    #[test]
    fn video_in_retweeted_status() {
        let raw = r#"{
            "idstr": "outer",
            "page_info": {"type": "webpage", "object_type": "webpage"},
            "retweeted_status": {
                "idstr": "inner",
                "page_info": {
                    "type": "11",
                    "object_type": "video",
                    "media_info": {"mp4_sd_url": "https://f.video.weibocdn.com/sd.mp4"}
                }
            }
        }"#;
        let s = parse(raw);
        assert!(s.is_video());
        let (url, src) = s.video_url_with_source().unwrap();
        assert_eq!(url, "https://f.video.weibocdn.com/sd.mp4");
        assert!(src.starts_with("retweeted_status."), "source={src}");

        // 外层也有视频时，外层优先
        let both = parse(
            r#"{"idstr":"o",
                "page_info":{"type":"11","object_type":"video",
                             "media_info":{"mp4_720p_mp4":"https://f.video.weibocdn.com/outer.mp4"}},
                "retweeted_status":{"idstr":"i","page_info":{"type":"11","object_type":"video",
                             "media_info":{"mp4_720p_mp4":"https://f.video.weibocdn.com/inner.mp4"}}}}"#,
        );
        assert_eq!(
            both.video_url().as_deref(),
            Some("https://f.video.weibocdn.com/outer.mp4")
        );
    }

    /// ⑤ `page_info` 存在但 `media_info` 为空 / 全空串 → 不 panic，返回 None。
    #[test]
    fn empty_media_info_returns_none() {
        let empty_obj = parse(r#"{"idstr":"5","page_info":{"type":"11","object_type":"video","media_info":{}}}"#);
        assert_eq!(empty_obj.video_url(), None);
        assert_eq!(empty_obj.video_duration(), None);
        assert_eq!(empty_obj.video_cover_url(), None);

        let blank_urls = parse(
            r#"{"idstr":"6","page_info":{"type":"11","object_type":"video",
                "media_info":{"mp4_720p_mp4":"","mp4_hd_url":"  ","stream_url":null,"playback_list":[]}}}"#,
        );
        assert_eq!(blank_urls.video_url(), None);
    }

    /// ⑥ `page_info` 整个缺失 → 不 panic，返回 None。
    #[test]
    fn missing_page_info_is_none() {
        let s = parse(r#"{"idstr":"7","text":"普通微博，没有卡片"}"#);
        assert!(s.page_info.is_none());
        assert!(s.page_info_parsed().is_none());
        assert!(!s.is_video());
        assert_eq!(s.video_url(), None);
        assert_eq!(s.video_cover_url(), None);
        assert_eq!(s.video_duration(), None);
    }
}

#[cfg(test)]
mod attitude_tests {
    use super::Status;

    fn parse(raw: &str) -> Status {
        serde_json::from_str(raw).expect("fixture 应能被宽松解析")
    }

    /// `attitudes_status` 是「当前用户是否点赞」的服务端真值（0/1）。
    #[test]
    fn attitudes_status_drives_is_liked() {
        assert!(parse(r#"{"idstr":"1","attitudes_status":1,"attitudes_count":9}"#).is_liked());
        assert!(!parse(r#"{"idstr":"2","attitudes_status":0,"attitudes_count":9}"#).is_liked());
    }

    /// 字段缺失（未登录/访客）时按未点赞处理，不能 panic。
    #[test]
    fn missing_attitudes_status_is_not_liked() {
        let s = parse(r#"{"idstr":"3","attitudes_count":5}"#);
        assert_eq!(s.attitudes_status, None);
        assert!(!s.is_liked());
    }
}

