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
use weibo_core::models::{weibo_strip_tags, HotItem, Status, User};

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
    /// 展示用图片 URL（已选中等尺寸）
    pub images: Vec<String>,
    pub is_ad: bool,
    pub is_long_text: bool,
    pub user: Option<UserDto>,
    /// 转发原微博（递归）
    pub retweeted: Option<Box<StatusDto>>,
}

impl From<&Status> for StatusDto {
    fn from(s: &Status) -> Self {
        Self {
            id: s.idstr.clone().unwrap_or_default(),
            time: s.display_time(),
            text: s.plain_text(),
            source: weibo_strip_tags(s.source.clone().unwrap_or_default()),
            reposts: s.reposts_count.unwrap_or(0),
            comments: s.comments_count.unwrap_or(0),
            likes: s.attitudes_count.unwrap_or(0),
            images: s.image_urls(),
            is_ad: s.is_ad_flag(),
            is_long_text: s.is_long_text.unwrap_or(false),
            user: s.user.as_ref().map(UserDto::from),
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
