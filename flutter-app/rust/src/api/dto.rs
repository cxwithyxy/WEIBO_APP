//! 桥接层 DTO：core 模型 → UI 就绪的扁平结构。
//!
//! # 为什么不直接把 core 的 `Status` / `User` 暴露给 Dart？
//!
//! FRB 对**外部 crate 的类型**默认生成 **opaque**（Dart 侧只是 Rust 对象句柄，
//! 读不到字段 —— 实测 `Status` 就变成了 `StatusImpl extends RustOpaque`）。
//! 两条路：
//!
//! 1. 逐字段写 `#[frb(mirror(...))]` 声明 —— 重复一遍字段表，且会与 core 漂移；
//! 2. 在这里定义 **DTO**，Rust 侧把 UI 需要的字段算好再交出去。
//!
//! 选 2，理由不只是绕开 opaque：
//!
//! - Dart 拿到的是**扁平、可直接绑到 widget** 的结构；
//! - 展示逻辑（剥 HTML、格式化时间、挑图片尺寸、判定广告）留在 Rust，
//!   UI 不用碰 `pic_infos` / `pic_ids` / HTML 标签这些内部细节 ——
//!   与 Android 版行为一致（同一份 core 逻辑）；
//! - 不把 `HashMap<String, PicInfo>` 这种原始结构跨 FFI 来回搬。

use weibo_core::auth::{QrSession, QrState, QrStatus};
use weibo_core::models::{
    weibo_strip_tags, Comment, HotBandItem, HotItem, Status, TimelinePage, TimelineRaw, User,
};

// ------------------------------------------------------------------ 用户

#[derive(Debug, Clone, Default)]
pub struct UserDto {
    pub id: String,
    pub name: String,
    pub avatar: String,
    pub verified: bool,
    pub description: String,
    pub followers: i64,
    pub friends: i64,
    pub statuses: i64,
}

impl From<&User> for UserDto {
    fn from(u: &User) -> Self {
        Self {
            id: u.idstr.clone().unwrap_or_default(),
            name: u.screen_name.clone().unwrap_or_default(),
            avatar: u.avatar.clone().unwrap_or_default(),
            verified: u.verified.unwrap_or(false),
            description: u.description.clone().unwrap_or_default(),
            followers: u.followers_count.unwrap_or(0),
            friends: u.friends_count.unwrap_or(0),
            statuses: u.statuses_count.unwrap_or(0),
        }
    }
}

// ------------------------------------------------------------------ 微博

#[derive(Debug, Clone, Default)]
pub struct StatusDto {
    pub id: String,
    /// 已格式化：YYYY/MM/DD HH:mm:SS
    pub time: String,
    /// 已剥 HTML 的纯文本
    pub text: String,
    /// 已剥 HTML 的来源（如「微博 weibo.com」）
    pub source: String,
    pub reposts: i32,
    pub comments: i32,
    pub likes: i32,
    /// 服务端记录的「当前用户是否已点赞」（core 的 `Status::is_liked`）。
    /// UI 必须用它初始化点赞图标；否则冷启动/刷新后已点赞的微博会显示成灰色。
    pub liked: bool,
    /// 展示用图片 URL（已选中等尺寸）
    pub images: Vec<String>,
    pub is_ad: bool,
    pub is_long_text: bool,
    pub user: Option<UserDto>,

    // ---- 视频（对应 core 的 `Status::is_video` / `video_*` 一族）----
    //
    // 说明：core 的视频字段**已经做了转发块回退** —— 外层没有 `page_info`
    // 视频时会取 `retweeted_status` 的。这里原样透传，UI 直接用即可。
    /// 本条（含转发块回退）是否带视频。
    pub is_video: bool,
    /// 视频直链（原样透传，**可能是 http://**）。
    pub video_url: Option<String>,
    /// 视频封面（通常是 https 的 sinaimg）。
    pub video_cover_url: Option<String>,
    /// 视频时长（秒）。
    pub video_duration: Option<i64>,
    /// 本条视频是否**来自 `retweeted_status`**。
    ///
    /// UI 需要它来避免封面重复：`video_url` 在转发场景会回退到转发块，
    /// 而转发块自身也会被序列化成一份 DTO、同样带视频字段。如果两层都画封面
    /// 就会出现两张。约定：**外层为 true 时封面画在转发块里，否则画在卡片层。**
    pub video_from_retweeted: bool,

    /// 转发原微博（递归）
    pub retweeted: Option<Box<StatusDto>>,
}

impl From<&Status> for StatusDto {
    fn from(s: &Status) -> Self {
        // `video_url_with_source` 的 source 会带 `retweeted_status.` 前缀，
        // 据此判断视频来自哪一层（复用 core 已有的公开 API，不重写判定逻辑）。
        let (video_url, video_from_retweeted) = match s.video_url_with_source() {
            Some((u, src)) => (Some(u), src.starts_with("retweeted_status.")),
            None => (None, false),
        };
        Self {
            id: s.idstr.clone().unwrap_or_default(),
            time: s.display_time(),
            text: s.plain_text(),
            source: weibo_strip_tags(s.source.clone().unwrap_or_default()),
            reposts: s.reposts_count.unwrap_or(0),
            comments: s.comments_count.unwrap_or(0),
            likes: s.attitudes_count.unwrap_or(0),
            liked: s.is_liked(),
            images: s.image_urls(),
            is_ad: s.is_ad_flag(),
            is_long_text: s.is_long_text.unwrap_or(false),
            user: s.user.as_ref().map(UserDto::from),
            is_video: s.is_video(),
            video_url,
            video_cover_url: s.video_cover_url(),
            video_duration: s.video_duration(),
            video_from_retweeted,
            retweeted: s
                .retweeted_status
                .as_ref()
                .map(|r| Box::new(StatusDto::from(r.as_ref()))),
        }
    }
}

// ------------------------------------------------------------------ 热搜

#[derive(Debug, Clone, Default)]
pub struct HotItemDto {
    pub word: String,
    pub heat: i64,
    pub rank: i32,
    pub label: String,
}

impl From<&HotItem> for HotItemDto {
    fn from(h: &HotItem) -> Self {
        Self {
            word: h.word.clone().unwrap_or_default(),
            heat: h.num.unwrap_or(0),
            rank: h.realpos.unwrap_or(0),
            label: h.label.clone().unwrap_or_default(),
        }
    }
}

// ------------------------------------------------------------------ 扫码登录

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QrStateDto {
    Waiting,
    Scanned,
    Expired,
    Confirmed,
    Error,
}

impl From<QrState> for QrStateDto {
    fn from(s: QrState) -> Self {
        match s {
            QrState::Waiting => QrStateDto::Waiting,
            QrState::Scanned => QrStateDto::Scanned,
            QrState::Expired => QrStateDto::Expired,
            QrState::Confirmed => QrStateDto::Confirmed,
            QrState::Error => QrStateDto::Error,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct QrSessionDto {
    pub qrid: String,
    pub image_url: String,
}

impl From<QrSession> for QrSessionDto {
    fn from(q: QrSession) -> Self {
        Self {
            qrid: q.qrid,
            image_url: q.image_url,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct QrStatusDto {
    pub state: Option<QrStateDto>,
    pub url: Option<String>,
    pub message: Option<String>,
}

impl From<QrStatus> for QrStatusDto {
    fn from(q: QrStatus) -> Self {
        Self {
            state: Some(q.state.into()),
            url: q.url,
            message: q.message,
        }
    }
}

// ------------------------------------------------------------------ 分页时间线

/// 一页时间线（带下一页游标）。
///
/// 游标语义按端点而异，别搞混：
///  - 首页时间线（`unreadfriendstimeline`）：游标是 `since_id`，把 `next_cursor` 原样回传；
///  - 关注时间线（`friendstimeline`）：`since_id` **实测无效**（第二页与第一页 100% 重叠），
///    必须用 **页码**，所以 `next_cursor` 在这里存的是「下一页页码」。
#[derive(Debug, Clone, Default)]
pub struct TimelinePageDto {
    pub statuses: Vec<StatusDto>,
    pub next_cursor: Option<String>,
}

impl From<TimelinePage> for TimelinePageDto {
    fn from(p: TimelinePage) -> Self {
        Self {
            statuses: p.statuses.iter().map(StatusDto::from).collect(),
            next_cursor: p.next_cursor,
        }
    }
}

impl From<TimelineRaw> for TimelinePageDto {
    fn from(p: TimelineRaw) -> Self {
        Self {
            statuses: p.statuses.iter().map(StatusDto::from).collect(),
            next_cursor: p.next_cursor,
        }
    }
}

// ------------------------------------------------------------------ 评论

#[derive(Debug, Clone, Default)]
pub struct CommentDto {
    pub id: String,
    /// 已格式化
    pub time: String,
    /// 已剥 HTML
    pub text: String,
    pub likes: i32,
    pub floor: i32,
    /// 是否为微博作者本人的评论
    pub is_author: bool,
    pub user: Option<UserDto>,
    /// 评论配图（原本漏了，导致图片评论只看得到文字）
    pub images: Vec<String>,
    /// 被回复的评论（递归）
    pub reply_to: Option<Box<CommentDto>>,
}

impl From<&Comment> for CommentDto {
    fn from(c: &Comment) -> Self {
        Self {
            id: c.idstr.clone().unwrap_or_default(),
            time: weibo_core::weibo_time_format(c.created_at.clone().unwrap_or_default()),
            text: c.plain_text(),
            likes: c.like_counts.unwrap_or(0),
            floor: c.floor_number.unwrap_or(0),
            is_author: c.is_author.unwrap_or(false),
            user: c.user.as_ref().map(UserDto::from),
            images: c.image_urls(),
            reply_to: c
                .reply_comment
                .as_ref()
                .map(|r| Box::new(CommentDto::from(r.as_ref()))),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CommentPageDto {
    pub comments: Vec<CommentDto>,
    /// 下一页游标（原样回传）
    pub next_max_id: Option<i64>,
    pub total: Option<i32>,
}

// ------------------------------------------------------------------ 热搜榜单

#[derive(Debug, Clone, Default)]
pub struct HotBandItemDto {
    pub word: String,
    pub note: String,
    pub heat: i64,
    pub rank: i32,
    pub realpos: i32,
    pub label: String,
    pub icon_desc: String,
}

impl From<&HotBandItem> for HotBandItemDto {
    fn from(h: &HotBandItem) -> Self {
        Self {
            word: h.word.clone().unwrap_or_default(),
            note: h.note.clone().unwrap_or_default(),
            heat: h.num.unwrap_or(0),
            rank: h.rank.unwrap_or(0),
            realpos: h.realpos.unwrap_or(0),
            label: h.label_name.clone().unwrap_or_default(),
            icon_desc: h.icon_desc.clone().unwrap_or_default(),
        }
    }
}

// ------------------------------------------------------------------ 本地缓存用

/// 一页时间线 + 服务端响应**原文**。
///
/// 原文用于本地缓存：重开 App 时用 `parseTimelineRaw` 把缓存原文解析回列表，
/// 走的是**和网络路径完全相同的解析代码**（原 Android 版 `FeedCache` 就是这个思路 ——
/// 存解析结果会因 core 换实现而失效，存原文不会）。
#[derive(Debug, Clone, Default)]
pub struct TimelineRawDto {
    pub raw: String,
    pub statuses: Vec<StatusDto>,
    pub next_cursor: Option<String>,
}

impl From<TimelineRaw> for TimelineRawDto {
    fn from(p: TimelineRaw) -> Self {
        Self {
            raw: p.raw,
            statuses: p.statuses.iter().map(StatusDto::from).collect(),
            next_cursor: p.next_cursor,
        }
    }
}

/// 单条微博：响应**原文** + 解析结果。
///
/// 原文按微博 id 存盘（`status/<id>.json`），下次打开详情页可直接用缓存先渲染。
#[derive(Debug, Clone, Default)]
pub struct StatusRawDto {
    pub raw: String,
    pub status: Option<StatusDto>,
}
