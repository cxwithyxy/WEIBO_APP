//! 真实 HTTP 引擎（reqwest 实现）
//!
//! 对应原 Kotlin 的 `JvmHttpEngine` / `OkHttpEngine`。
//!
//! 实现约定（上层 WeiboHttp 依赖）：
//!  - **不跟随重定向** → `Policy::none()`（微博登录依赖逐跳吸收 Set-Cookie）
//!  - **不管理 cookie** → 不自带 cookie store
//!  - **不自动重试**
//!
//! TLS 说明（重要）：
//!  - 显式使用 **内置 Mozilla 根证书**（webpki-roots）+ aws-lc-rs provider。
//!  - 不能改用 reqwest 的 `rustls` feature：它会绑 `rustls-platform-verifier`，
//!    后者在 Android 上必须先初始化（要 JNI Env + Android Context），
//!    否则 panic "Expect rustls-platform-verifier to be initialized"，
//!    且在 reqwest 内部线程里，上层只能看到 "event loop thread panicked"。
//!  - 自备配置后不依赖任何平台胶水，host / Android / iOS 行为一致。

use crate::http::{HttpEngine, RawRequest, RawResponse, WeiboError};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Object))]
pub struct ReqwestEngine {
    client: reqwest::blocking::Client,
}

/// 构造使用内置 Mozilla 根证书的 rustls 配置。
///
/// 两条都不能省：
///  - **安装默认 crypto provider**（aws-lc-rs）—— 否则 `ClientConfig::builder()` 会 panic
///    "no process-level CryptoProvider available"。
///  - **显式装根证书** —— 不使用平台校验器。
fn build_tls_config() -> Result<rustls::ClientConfig, WeiboError> {
    // 幂等：已装过则返回 Err，忽略即可
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

    Ok(rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth())
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
impl ReqwestEngine {
    #[cfg_attr(feature = "uniffi-ffi", uniffi::constructor)]
    pub fn new() -> Result<Arc<Self>, WeiboError> {
        Self::with_timeouts(20, 25)
    }

    /// 自定义超时（秒）：connect, request
    #[cfg_attr(feature = "uniffi-ffi", uniffi::constructor)]
    pub fn with_timeouts(connect_secs: u64, request_secs: u64) -> Result<Arc<Self>, WeiboError> {
        let tls = build_tls_config()?;
        let client = reqwest::blocking::Client::builder()
            // 关键：绝不自动跟随重定向
            .redirect(reqwest::redirect::Policy::none())
            // 关键：用自备 TLS 配置，绕开平台证书校验器（见文件头说明）
            .use_preconfigured_tls(tls)
            .connect_timeout(Duration::from_secs(connect_secs))
            .timeout(Duration::from_secs(request_secs))
            .build()
            .map_err(|e| WeiboError::http(format!("build client: {e}")))?;
        Ok(Arc::new(Self { client }))
    }
}

impl HttpEngine for ReqwestEngine {
    fn execute(&self, request: RawRequest) -> Result<RawResponse, WeiboError> {
        let method = reqwest::Method::from_bytes(request.method.as_bytes())
            .map_err(|e| WeiboError::protocol(format!("bad method {}: {e}", request.method)))?;

        let mut rb = self.client.request(method, &request.url);
        for (k, v) in &request.headers {
            rb = rb.header(k.as_str(), v.as_str());
        }
        if let Some(b) = request.body {
            rb = rb.body(b);
        }

        let resp = rb
            .send()
            .map_err(|e| WeiboError::http(format!("send {}: {e}", request.url)))?;

        let status = resp.status().as_u16();

        let mut headers: HashMap<String, Vec<String>> = HashMap::new();
        for (name, value) in resp.headers().iter() {
            // 用原始大小写友好的名字（Set-Cookie 等）
            let key = name.as_str().to_string();
            headers
                .entry(key)
                .or_default()
                .push(value.to_str().unwrap_or_default().to_string());
        }

        let body = resp
            .bytes()
            .map_err(|e| WeiboError::http(format!("read body {}: {e}", request.url)))?
            .to_vec();

        Ok(RawResponse {
            status,
            headers,
            body,
        })
    }
}
