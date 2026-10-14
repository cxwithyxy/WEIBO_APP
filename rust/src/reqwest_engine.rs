//! 真实 HTTP 引擎（reqwest 实现）
//!
//! 对应原 Kotlin 的 `JvmHttpEngine` / `OkHttpEngine`。
//!
//! 实现约定（上层 WeiboHttp 依赖）：
//!  - **不跟随重定向** → `Policy::none()`（微博登录依赖逐跳吸收 Set-Cookie）
//!  - **不管理 cookie** → 不自带 cookie store
//!  - **不自动重试**

use crate::http::{HttpEngine, RawRequest, RawResponse, WeiboError};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

#[derive(uniffi::Object)]
pub struct ReqwestEngine {
    client: reqwest::blocking::Client,
}

#[uniffi::export]
impl ReqwestEngine {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, WeiboError> {
        Self::with_timeouts(20, 25)
    }

    /// 自定义超时（秒）：connect, request
    #[uniffi::constructor]
    pub fn with_timeouts(connect_secs: u64, request_secs: u64) -> Result<Arc<Self>, WeiboError> {
        let client = reqwest::blocking::Client::builder()
            // 关键：绝不自动跟随重定向
            .redirect(reqwest::redirect::Policy::none())
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
