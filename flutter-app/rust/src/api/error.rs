//! 桥接层错误：**只向 Dart 暴露可读信息**。
//!
//! # 为什么不直接用 core 的 `WeiboError`？
//!
//! 它是**外部 crate** 的类型，FRB 只能生成 opaque 句柄
//! （`abstract class WeiboError implements RustOpaqueInterface`）——
//! Dart 侧读不到 `detail` 字段，界面**无法展示失败原因**。
//!
//! 定义在 `crate::api` 下的类型则会被 FRB 正常镜像成普通 Dart 类，
//! 于是 Dart 能直接读 `e.message`。
//!
//! 这一点值得较真：迁移过程中已经因为「错误被静默吞掉」踩过一次坑
//! （`unwrap_or_default()` 把解析失败伪装成「响应无 ok 字段」），
//! 界面上看不到真实原因会显著拖慢排查。

use std::fmt;

use weibo_core::http::WeiboError;

/// 桥接层错误。
#[derive(Debug, Clone)]
pub struct WeiboFailure {
    /// `"http"` | `"protocol"` | `"init"`
    pub kind: String,
    /// 人类可读的失败原因（可直接展示到界面）
    pub message: String,
}

impl WeiboFailure {
    pub fn new(kind: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            message: message.into(),
        }
    }
}

impl From<WeiboError> for WeiboFailure {
    fn from(e: WeiboError) -> Self {
        match e {
            WeiboError::Http { detail } => Self::new("http", detail),
            WeiboError::Protocol { detail } => Self::new("protocol", detail),
        }
    }
}

impl fmt::Display for WeiboFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for WeiboFailure {}
