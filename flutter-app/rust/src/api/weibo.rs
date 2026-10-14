//! Flutter 桥接层：把 Rust core 暴露给 Dart。
//!
//! 设计要点：
//!
//! 1. **用 Rust 自带的 `ReqwestEngine`**，不像 Android 版那样注入平台 HTTP 实现
//!    （Android 用 OkHttp 实现 Rust 的 `HttpEngine` trait）。因此 Flutter 侧
//!    **不需要任何网络胶水** —— 这是选 Flutter 路线省下来的第一块成本。
//!
//! 2. **全局单例**（对应原 App 的 `WeiboService` object）。cookie 由 Rust 的
//!    `WeiboHttp` 在内存里维护，必须全 App 共用同一个 `WeiboClient`，否则登录态不共享。
//!
//! 3. **所有 core 调用都经 [`on_blocking_pool`]** —— 这是本文件最要紧的一点，
//!    原因见该函数注释（不这样做会 panic）。
//!
//! 4. 对外只返回 [`crate::api::dto`] 里的 DTO、只抛 [`WeiboFailure`]
//!    （原因见 `dto.rs` / `error.rs` 顶部注释）。

use std::sync::{Arc, OnceLock};

use weibo_core::client::WeiboClient;
use weibo_core::reqwest_engine::ReqwestEngine;

use crate::api::dto::{HotItemDto, QrSessionDto, QrStatusDto, StatusDto, UserDto};
use crate::api::error::WeiboFailure;

static CLIENT: OnceLock<Arc<WeiboClient>> = OnceLock::new();

/// 在**阻塞线程池**上执行 core 调用。
///
/// # 为什么必须这样
///
/// FRB 默认在 **Tokio 运行时**的线程上执行同步函数；而 core 的 `ReqwestEngine`
/// 用的是 `reqwest::blocking`（它自带一个内部 Tokio 运行时）。
/// 在异步上下文里创建/丢弃那个内部运行时会直接 panic：
///
/// ```text
/// Cannot drop a runtime in a context where blocking is not allowed.
/// This happens when a runtime is dropped from within an asynchronous context.
///   at tokio/src/runtime/blocking/shutdown.rs
/// ```
///
/// 这个 panic 已在主机上用测试复现（见文件底部 `tokio_runtime_context`），
/// 也正是在 Android 真机上看到的 `PanicException(event loop thread panicked)`。
///
/// `spawn_blocking` 把调用挪到 Tokio 的阻塞线程池 —— 在那里阻塞是允许的。
async fn on_blocking_pool<T, F>(f: F) -> Result<T, WeiboFailure>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, WeiboFailure> + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| WeiboFailure::new("panic", format!("后台线程异常: {e}")))?
}

fn client() -> Result<Arc<WeiboClient>, WeiboFailure> {
    CLIENT
        .get()
        .cloned()
        .ok_or_else(|| WeiboFailure::new("init", "客户端未初始化，请先调用 initClient()"))
}

// ------------------------------------------------------------------ 会话

/// 初始化全局客户端（幂等）。App 启动时调用一次。
///
/// 必须在任何其他接口之前调用；`ReqwestEngine::new()` 会初始化 TLS，
/// 失败时返回错误而不是 panic。
pub async fn init_client() -> Result<(), WeiboFailure> {
    if CLIENT.get().is_some() {
        return Ok(());
    }
    on_blocking_pool(|| {
        let engine = ReqwestEngine::new().map_err(WeiboFailure::from)?;
        let _ = CLIENT.set(WeiboClient::new(engine));
        Ok(())
    })
    .await
}

/// 是否已登录（cookie 中有 SUB）
pub async fn is_logged_in() -> Result<bool, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || Ok(c.is_logged_in())).await
}

/// 当前登录 uid（未登录为 null）
pub async fn uid() -> Result<Option<String>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || Ok(c.uid())).await
}

/// 从 Netscape 格式 cookie 文件恢复登录态，返回是否成功
pub async fn restore(cookie_file: String) -> Result<bool, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || Ok(c.restore(cookie_file))).await
}

/// 把当前 cookie 存成 Netscape 格式文件
pub async fn save(cookie_file: String) -> Result<(), WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || c.save(cookie_file).map_err(WeiboFailure::from)).await
}

// ------------------------------------------------------------------ 只读接口

/// 热搜榜（**不需要登录**，适合当冒烟测试）
pub async fn hot_search() -> Result<Vec<HotItemDto>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let list = c.hot_search().map_err(WeiboFailure::from)?;
        Ok(list.iter().map(HotItemDto::from).collect())
    })
    .await
}

/// 首页时间线；`since_id` 传空串表示拉最新
pub async fn home_timeline(count: u32, since_id: String) -> Result<Vec<StatusDto>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let list = c
            .home_timeline(count, since_id)
            .map_err(WeiboFailure::from)?;
        Ok(list.iter().map(StatusDto::from).collect())
    })
    .await
}

/// 关注时间线
pub async fn following_timeline(count: u32) -> Result<Vec<StatusDto>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let list = c.following_timeline(count).map_err(WeiboFailure::from)?;
        Ok(list.iter().map(StatusDto::from).collect())
    })
    .await
}

/// 单条微博详情
pub async fn status_detail(mid: String) -> Result<StatusDto, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let s = c.status_detail(mid).map_err(WeiboFailure::from)?;
        Ok(StatusDto::from(&s))
    })
    .await
}

/// 用户资料
pub async fn user_info(uid: String) -> Result<Option<UserDto>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let u = c.user_info(uid).map_err(WeiboFailure::from)?;
        Ok(u.as_ref().map(UserDto::from))
    })
    .await
}

/// 搜索微博
pub async fn search(q: String, count: u32, page: u32) -> Result<Vec<StatusDto>, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let list = c.search(q, count, page).map_err(WeiboFailure::from)?;
        Ok(list.iter().map(StatusDto::from).collect())
    })
    .await
}

// ------------------------------------------------------------------ 扫码登录

/// 登录页 URL（webview 用）
pub fn signin_url() -> String {
    weibo_core::auth::signin_url()
}

/// 建立登录会话（预热 cookie）
pub async fn auth_prepare() -> Result<(), WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || c.auth().prepare().map_err(WeiboFailure::from)).await
}

/// 生成登录二维码
pub async fn auth_create_qr(size: u32) -> Result<QrSessionDto, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let s = c.auth().create_qr(size).map_err(WeiboFailure::from)?;
        Ok(s.into())
    })
    .await
}

/// 轮询扫码状态
pub async fn auth_poll(qrid: String) -> Result<QrStatusDto, WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || {
        let s = c.auth().poll(qrid).map_err(WeiboFailure::from)?;
        Ok(s.into())
    })
    .await
}

/// 扫码确认后完成登录（吸收 cookie）
pub async fn auth_complete(url: String) -> Result<(), WeiboFailure> {
    let c = client()?;
    on_blocking_pool(move || c.auth().complete(url).map_err(WeiboFailure::from)).await
}

// ------------------------------------------------------------------ 回归测试

#[cfg(test)]
mod tests {
    use super::*;

    /// 回归测试：证明经 `on_blocking_pool` 包装后，
    /// 在 Tokio 运行时上下文里调用阻塞式 core **不再 panic**。
    ///
    /// 背景：未包装时会 panic
    /// `Cannot drop a runtime in a context where blocking is not allowed.`
    #[test]
    fn tokio_runtime_context() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            match init_client().await {
                Ok(()) => println!("✓ init_client 成功"),
                Err(e) => {
                    println!("✗ init_client 失败: {e}");
                    return;
                }
            }
            match hot_search().await {
                Ok(v) => println!("✓ hot_search 成功，{} 条", v.len()),
                Err(e) => println!("✗ hot_search 失败: {e}"),
            }
        });
    }
}
