//! 扫码登录（微博 SSO v2）—— Rust 移植
//!
//! 对应原 Kotlin `WeiboAuth.kt`。
//!
//! 流程：
//!   1. `prepare()`      访问登录页，建立会话
//!   2. `create_qr()`    取二维码 qrid + 图片 URL
//!   3. `poll(qrid)`     轮询扫描状态
//!   4. `complete(url)`  跟随回调，拿到 SUB 等 cookie

use crate::http::{enc, WeiboError, WeiboHttp, HOST_PASSPORT};
use serde::Deserialize;
use std::sync::Arc;

/// 登录页（步骤 1）
pub fn signin_url() -> String {
    format!("{HOST_PASSPORT}/sso/signin?entry=wapssso&source=wapssowb")
}

/// 扫码完成后的落地页
const POST_LOGIN_URL: &str = "https://m.weibo.cn/";
const VER: &str = "20250520";

/// 轮询返回码
const RC_CONFIRMED: i64 = 20000000;
const RC_NOT_USED: i64 = 50114001;
const RC_SCANNED: i64 = 50114002;
const RC_EXPIRED_A: i64 = 50114003;
const RC_EXPIRED_B: i64 = 50114004;
const RC_EXPIRED_C: i64 = 50114015;

/// 按 Kotlin 的方式格式化可空值（值本身 / `null`）——
/// Rust 的 `{:?}` 会输出 `Some(x)` / `None`，与原实现不一致。
fn kt_opt<T: std::fmt::Display>(v: Option<T>) -> String {
    match v {
        Some(x) => x.to_string(),
        None => "null".to_string(),
    }
}

// ------------------------------------------------------------------ 类型

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct QrSession {
    pub qrid: String,
    pub image_url: String,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum QrState {
    Waiting,
    Scanned,
    Expired,
    Confirmed,
    Error,
}

#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct QrStatus {
    pub state: QrState,
    pub url: Option<String>,
    pub message: Option<String>,
}

impl Default for QrState {
    fn default() -> Self {
        QrState::Error
    }
}

// ------------------------------------------------------ 内部响应信封

#[derive(Debug, Default, Deserialize)]
struct QrImageResp {
    retcode: Option<i64>,
    msg: Option<String>,
    data: Option<QrImageData>,
}

#[derive(Debug, Default, Deserialize)]
struct QrImageData {
    qrid: Option<String>,
    image: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct QrCheckResp {
    retcode: Option<i64>,
    msg: Option<String>,
    data: Option<QrCheckData>,
}

#[derive(Debug, Default, Deserialize)]
struct QrCheckData {
    url: Option<String>,
}

// ------------------------------------------------------------------ 实现

#[derive(uniffi::Object)]
pub struct WeiboAuth {
    http: Arc<WeiboHttp>,
}

#[uniffi::export]
impl WeiboAuth {
    #[uniffi::constructor]
    pub fn new(http: Arc<WeiboHttp>) -> Arc<Self> {
        Arc::new(Self { http })
    }

    /// 步骤 1：先访问登录页，拿 X-CSRF-TOKEN 等 cookie
    pub fn prepare(&self) -> Result<(), WeiboError> {
        self.http.get(signin_url(), None, false)?;
        Ok(())
    }

    /// 步骤 2：取二维码
    pub fn create_qr(&self, size: u32) -> Result<QrSession, WeiboError> {
        let url = format!("{HOST_PASSPORT}/sso/v2/qrcode/image?entry=wapssso&size={size}");
        let json = self.http.get(url, Some(signin_url()), false)?;
        let r: QrImageResp = serde_json::from_str(&json).unwrap_or_default();
        let d = r.data.ok_or_else(|| {
            WeiboError::protocol(format!(
                "二维码获取失败 retcode={} msg={}",
                kt_opt(r.retcode),
                kt_opt(r.msg)
            ))
        })?;
        let qrid = d
            .qrid
            .ok_or_else(|| WeiboError::protocol("响应缺少 qrid"))?;
        let image = d
            .image
            .ok_or_else(|| WeiboError::protocol("响应缺少 image"))?;
        Ok(QrSession {
            qrid,
            image_url: image,
        })
    }

    /// 步骤 3：轮询一次扫描状态
    pub fn poll(&self, qrid: String) -> Result<QrStatus, WeiboError> {
        let url = format!(
            "{HOST_PASSPORT}/sso/v2/qrcode/check?entry=wapssso&source=wapssowb\
             &url={}&qrid={}&disp=&rid=norid&ver={VER}",
            enc(POST_LOGIN_URL),
            enc(&qrid)
        );
        let json = self.http.get(url, Some(signin_url()), false)?;
        let Ok(r) = serde_json::from_str::<QrCheckResp>(&json) else {
            return Ok(QrStatus {
                state: QrState::Error,
                url: None,
                message: Some("空响应".into()),
            });
        };

        let (state, url) = match r.retcode {
            Some(RC_CONFIRMED) => (QrState::Confirmed, r.data.and_then(|d| d.url)),
            Some(RC_NOT_USED) => (QrState::Waiting, None),
            Some(RC_SCANNED) => (QrState::Scanned, None),
            Some(RC_EXPIRED_A) | Some(RC_EXPIRED_B) | Some(RC_EXPIRED_C) => (QrState::Expired, None),
            _ => (QrState::Error, None),
        };

        // 对应 Kotlin `message = r.msg ?: "retcode=${r.retcode}"`（仅 ERROR 时用兜底文案）
        let message = if state == QrState::Error && r.msg.is_none() {
            Some(format!("retcode={}", kt_opt(r.retcode)))
        } else {
            r.msg
        };

        Ok(QrStatus {
            state,
            url,
            message,
        })
    }

    /// 步骤 4：已确认 → 跟随回调链（cookie 自动落到 WeiboHttp 的 cookie 罐）
    pub fn complete(&self, url: String) -> Result<(), WeiboError> {
        self.http.get(url, Some(signin_url()), false)?;
        Ok(())
    }
}

// 非 FFI 方法（Rust 侧/CLI 使用）
impl WeiboAuth {
    /// 阻塞式完整登录：取码 → 回调展示二维码 → 等待扫描 → 完成。
    ///
    /// Kotlin 版的回调在跨 FFI 场景下由调用方自行驱动（App 就是这么做的），
    /// 所以这里只给 Rust 侧（CLI）使用。
    pub fn login_blocking(
        &self,
        timeout_seconds: u64,
        poll_interval_ms: u64,
        mut on_qr: impl FnMut(&QrSession),
        mut on_state: impl FnMut(&QrStatus),
    ) -> Result<bool, WeiboError> {
        if !self.http.is_logged_in() {
            self.prepare()?;
        }
        let session = self.create_qr(300)?;
        on_qr(&session);

        let deadline =
            std::time::Instant::now() + std::time::Duration::from_secs(timeout_seconds);
        while std::time::Instant::now() < deadline {
            let st = self.poll(session.qrid.clone())?;
            on_state(&st);
            match st.state {
                QrState::Confirmed => {
                    if let Some(u) = st.url {
                        self.complete(u)?;
                    }
                    return Ok(self.http.is_logged_in());
                }
                QrState::Expired | QrState::Error => return Ok(false),
                _ => std::thread::sleep(std::time::Duration::from_millis(poll_interval_ms)),
            }
        }
        Ok(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::http::{HttpEngine, RawRequest, RawResponse};
    use std::collections::{HashMap, VecDeque};
    use std::sync::Mutex;

    struct ScriptedEngine {
        script: Mutex<VecDeque<RawResponse>>,
        log: Mutex<Vec<RawRequest>>,
    }

    impl ScriptedEngine {
        fn new(v: Vec<RawResponse>) -> Arc<Self> {
            Arc::new(Self {
                script: Mutex::new(v.into()),
                log: Mutex::new(Vec::new()),
            })
        }
        fn urls(&self) -> Vec<String> {
            self.log
                .lock()
                .unwrap()
                .iter()
                .map(|r| r.url.clone())
                .collect()
        }
    }

    impl HttpEngine for ScriptedEngine {
        fn execute(&self, request: RawRequest) -> Result<RawResponse, WeiboError> {
            self.log.lock().unwrap().push(request);
            Ok(self
                .script
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(RawResponse {
                    status: 200,
                    headers: HashMap::new(),
                    body: Vec::new(),
                }))
        }
    }

    fn body(s: &str) -> RawResponse {
        RawResponse {
            status: 200,
            headers: HashMap::new(),
            body: s.as_bytes().to_vec(),
        }
    }

    fn auth_with(responses: Vec<&str>) -> (Arc<WeiboAuth>, Arc<ScriptedEngine>) {
        let e = ScriptedEngine::new(responses.into_iter().map(body).collect());
        let http = WeiboHttp::new(e.clone(), None);
        (WeiboAuth::new(http), e)
    }

    #[test]
    fn create_qr_ok() {
        let (auth, e) = auth_with(vec![r#"{"retcode":0,"data":{"qrid":"Q1","image":"https://v2.qr.weibo.cn/x.png"}}"#]);
        let s = auth.create_qr(300).unwrap();
        assert_eq!(s.qrid, "Q1");
        assert_eq!(s.image_url, "https://v2.qr.weibo.cn/x.png");
        assert!(e.urls()[0].contains("size=300"));
    }

    #[test]
    fn create_qr_missing_data_errors() {
        let (auth, _) = auth_with(vec![r#"{"retcode":-1,"msg":"bad"}"#]);
        let err = auth.create_qr(300).unwrap_err();
        assert!(format!("{err}").contains("二维码获取失败"));
    }

    #[test]
    fn poll_state_mapping() {
        // 每个 retcode 对应一个状态
        let cases: Vec<(&str, QrState)> = vec![
            (r#"{"retcode":20000000,"data":{"url":"https://passport.weibo.com/cb"}}"#, QrState::Confirmed),
            (r#"{"retcode":50114001,"msg":"未使用"}"#, QrState::Waiting),
            (r#"{"retcode":50114002,"msg":"已扫描"}"#, QrState::Scanned),
            (r#"{"retcode":50114003,"msg":"已过期"}"#, QrState::Expired),
            (r#"{"retcode":50114004,"msg":"已过期"}"#, QrState::Expired),
            (r#"{"retcode":50114015,"msg":"已过期"}"#, QrState::Expired),
            (r#"{"retcode":99999,"msg":"未知"}"#, QrState::Error),
        ];
        for (json, want) in cases {
            let (auth, _) = auth_with(vec![json]);
            let st = auth.poll("Q1".into()).unwrap();
            assert_eq!(st.state, want, "json={json}");
        }
    }

    #[test]
    fn poll_confirmed_carries_url() {
        let (auth, e) = auth_with(vec![r#"{"retcode":20000000,"data":{"url":"https://passport.weibo.com/cb?x=1"}}"#]);
        let st = auth.poll("Q1".into()).unwrap();
        assert_eq!(st.state, QrState::Confirmed);
        assert_eq!(st.url.as_deref(), Some("https://passport.weibo.com/cb?x=1"));
        // 轮询 URL 必须带上编码后的 qrid 与落地页
        let u = &e.urls()[0];
        assert!(u.contains("entry=wapssso"));
        assert!(u.contains("qrid=Q1"));
        assert!(u.contains("ver=20250520"));
        assert!(u.contains(&enc("https://m.weibo.cn/")));
    }

    #[test]
    fn poll_error_reports_retcode() {
        let (auth, _) = auth_with(vec![r#"{"retcode":12345}"#]);
        let st = auth.poll("Q1".into()).unwrap();
        assert_eq!(st.state, QrState::Error);
        assert_eq!(st.message.as_deref(), Some("retcode=12345"));
    }

    #[test]
    fn prepare_then_complete_hits_expected_urls() {
        let (auth, e) = auth_with(vec!["{}", "{}"]);
        auth.prepare().unwrap();
        auth.complete("https://passport.weibo.com/cb".into()).unwrap();
        let urls = e.urls();
        assert!(urls[0].contains("/sso/signin"));
        assert_eq!(urls[1], "https://passport.weibo.com/cb");
    }
}
