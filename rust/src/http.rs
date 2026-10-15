//! 微博 HTTP 层（Rust 移植）
//!
//! 对应原 Kotlin `WeiboCore.kt` 里的 `WeiboHttp`。
//!
//! 为什么要自己管 cookie + 自己跟随重定向（不用现成 cookie store）：
//!   1) 外部注入的 cookie 可能不被发出（实测导致 403 / 跳登录页）
//!   2) 自动跟随重定向时，**中间跳转的 Set-Cookie 会被丢弃**
//! 微博 SSO 登录恰恰依赖跨跳转的 Set-Cookie，所以必须自己接管。
//!
//! 关键约束：cookie 罐**必须按 (域名, 名字) 做键**。
//! SSO 回调链会在 .weibo.com / .sina.com.cn / .sina.cn / .weibo.cn
//! 依次下发同名 `SUB`；只按名字存会互相覆盖，导致 weibo.com 拿不到登录态。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// 桌面 Chrome UA。
///
/// 背景：本项目的接口全是 `weibo.com/ajax/*`（**桌面网页端**接口，配 Referer +
/// X-Requested-With 用），所以桌面 UA 与接口语义最一致 —— 原 Kotlin 版用的就是这个。
pub const DESKTOP_UA: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

/// Android Chrome UA。
///
/// 用户担心风控/限频，要求换成安卓 Chrome。留成常量方便随时切。
/// 注意风险：我们的端点是**桌面网页端**的，UA 写成 Android 而打的又是桌面接口，
/// 语义上反而不一致（真实客户端不会这样），需实测确认不影响可用性。
pub const ANDROID_UA: &str =
    "Mozilla/5.0 (Linux; Android 15; SM-A5360 Build/UP1A.231005.007) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";

/// 当前实际使用的 UA（改这一个开关就能切换）
pub const DEFAULT_UA: &str = DESKTOP_UA;
pub const HOST_WEIBO: &str = "https://weibo.com";
pub const HOST_PASSPORT: &str = "https://passport.weibo.com";

// ------------------------------------------------------------------
// FFI 数据类型
// ------------------------------------------------------------------

/// 一次「不跟随重定向、不管理 cookie」的原始请求。
#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct RawRequest {
    pub url: String,
    pub method: String,
    pub headers: HashMap<String, String>,
    pub body: Option<Vec<u8>>,
}

/// 原始响应。引擎**不得**跟随重定向、不得管理 cookie、不得重试。
#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct RawResponse {
    pub status: u16,
    pub headers: HashMap<String, Vec<String>>,
    pub body: Vec<u8>,
}

impl RawResponse {
    /// 大小写不敏感地取某个响应头的全部值（保序）
    pub fn header_values(&self, name: &str) -> Vec<String> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.clone())
            .unwrap_or_default()
    }

    /// 取第一个值
    pub fn header(&self, name: &str) -> Option<String> {
        self.header_values(name).into_iter().next()
    }

    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).to_string()
    }
}

/// 平台 HTTP 引擎。
///
/// 实现约定（非常重要，上层重定向/cookie 逻辑依赖它）：
///  - **不跟随重定向**，原样返回 3xx 与 Location
///  - **不管理 cookie**，原样回传所有 Set-Cookie
///  - **不自动重试**
#[cfg_attr(feature = "uniffi-ffi", uniffi::export(with_foreign))]
pub trait HttpEngine: Send + Sync {
    fn execute(&self, request: RawRequest) -> Result<RawResponse, WeiboError>;
}

#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Error))]
pub enum WeiboError {
    // 具名字段不能叫 `message` —— uniffi 生成的 Kotlin 错误类继承 Exception，
    // 会与 `Throwable.message` 冲突导致 Kotlin 编译失败。
    //
    // 已知绑定生成器行为：uniffi 生成的 Kotlin 异常里，`message` 会被加 `detail=` 前缀
    //（形如 `detail=首页时间线 失败: ...`）。干净的原文通过异常的 `.detail` 属性读取。
    // 这是表示层装饰，不影响异常类型与语义。
    #[error("{detail}")]
    Http { detail: String },
    #[error("{detail}")]
    Protocol { detail: String },
}

impl WeiboError {
    pub fn http(msg: impl Into<String>) -> Self {
        WeiboError::Http { detail: msg.into() }
    }
    pub fn protocol(msg: impl Into<String>) -> Self {
        WeiboError::Protocol { detail: msg.into() }
    }
}

// ------------------------------------------------------------------
// cookie 罐
// ------------------------------------------------------------------

#[derive(Clone, PartialEq, Eq, Debug)]
struct CookieKey {
    domain: String,
    name: String,
}

/// 内部状态。`jar` 用 Vec 保持**插入顺序**（对应 Kotlin 的 LinkedHashMap）：
/// 已存在的键只更新值、**不改变位置** —— 这决定了 `cookie_value` 取到的「第一个」是谁。
struct Inner {
    jar: Vec<(CookieKey, String)>,
    ua: String,
}

impl Inner {
    /// 某 host 该带的 Cookie 头
    fn cookie_header(&self, host: &str) -> String {
        self.jar
            .iter()
            .filter(|(k, _)| {
                let d = k.domain.strip_prefix('.').unwrap_or(&k.domain);
                host == d || host.ends_with(&format!(".{d}"))
            })
            .map(|(k, v)| format!("{}={}", k.name, v))
            .collect::<Vec<_>>()
            .join("; ")
    }

    /// 已存在的键原地更新；新键追加到末尾（LinkedHashMap 语义）
    fn set(&mut self, key: CookieKey, value: String) {
        if let Some(slot) = self.jar.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = value;
        } else {
            self.jar.push((key, value));
        }
    }

    fn remove(&mut self, key: &CookieKey) {
        self.jar.retain(|(k, _)| k != key);
    }

    /// 吸收一次响应里的所有 Set-Cookie
    fn absorb(&mut self, host: &str, resp: &RawResponse) {
        for raw in resp.header_values("Set-Cookie") {
            let seg: Vec<&str> = raw.split(';').collect();
            let kv = seg[0].trim();
            let Some(i) = kv.find('=') else { continue };
            if i == 0 {
                continue;
            }
            let name = kv[..i].trim().to_string();
            let value = kv[i + 1..].trim().to_string();

            let attrs: Vec<String> = seg[1..].iter().map(|s| s.trim().to_string()).collect();
            let dom = attrs
                .iter()
                .find(|a| a.to_ascii_lowercase().starts_with("domain="))
                .map(|a| a[7..].trim().to_string())
                .unwrap_or_else(|| host.to_string());

            let key = CookieKey { domain: dom, name };
            let expiring = attrs.iter().any(|a| {
                let l = a.to_ascii_lowercase();
                (l.starts_with("expires=") && a.contains("1970")) || l.starts_with("max-age=0")
            });
            let deleted = value.eq_ignore_ascii_case("deleted") || expiring;

            if deleted {
                self.remove(&key);
            } else {
                self.set(key, value);
            }
        }
    }

    fn cookie_value(&self, name: &str) -> Option<String> {
        self.jar
            .iter()
            .find(|(k, _)| k.name == name)
            .map(|(_, v)| v.clone())
    }

    fn cookie_header_string(&self) -> String {
        self.jar
            .iter()
            .map(|(k, v)| format!("{}={}", k.name, v))
            .collect::<Vec<_>>()
            .join("; ")
    }
}

/// 会话状态快照 —— 供外部观察/对比（跨平台一致性验证用）
#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Record))]
#[derive(Clone, Debug)]
pub struct CookieEntry {
    pub domain: String,
    pub name: String,
    pub value: String,
}

// ------------------------------------------------------------------
// WeiboHttp
// ------------------------------------------------------------------

struct Res {
    status: u16,
    location: Option<String>,
    body: String,
}

#[cfg_attr(feature = "uniffi-ffi", derive(uniffi::Object))]
pub struct WeiboHttp {
    engine: Arc<dyn HttpEngine>,
    inner: Mutex<Inner>,
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
impl WeiboHttp {
    #[cfg_attr(feature = "uniffi-ffi", uniffi::constructor)]
    pub fn new(engine: Arc<dyn HttpEngine>, ua: Option<String>) -> Arc<Self> {
        Arc::new(Self {
            engine,
            inner: Mutex::new(Inner {
                jar: Vec::new(),
                ua: ua.unwrap_or_else(|| DEFAULT_UA.to_string()),
            }),
        })
    }

    /// GET，自动跟随最多 10 跳重定向，每跳都吸收 Set-Cookie
    pub fn get(
        &self,
        url: String,
        referer: Option<String>,
        ajax: bool,
    ) -> Result<String, WeiboError> {
        let mut current = url;
        let mut hops = 0;
        loop {
            let res = self.raw(&current, "GET", None, referer.as_deref(), ajax)?;
            if let Some(loc) = &res.location {
                if (300..400).contains(&res.status) && hops < 10 {
                    current = Self::resolve(&current, loc)?;
                    hops += 1;
                    continue;
                }
            }
            return Ok(res.body);
        }
    }

    /// POST 表单（同样跟随重定向；跳转后不带 body）
    pub fn post_form(
        &self,
        url: String,
        form: HashMap<String, String>,
        referer: Option<String>,
        ajax: bool,
    ) -> Result<String, WeiboError> {
        let payload = form
            .iter()
            .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
            .collect::<Vec<_>>()
            .join("&");
        let mut current = url;
        let mut hops = 0;
        let mut body = Some(payload);
        loop {
            let res = self.raw(&current, "POST", body.as_deref(), referer.as_deref(), ajax)?;
            if let Some(loc) = &res.location {
                if (300..400).contains(&res.status) && hops < 10 {
                    current = Self::resolve(&current, loc)?;
                    hops += 1;
                    body = None;
                    continue;
                }
            }
            return Ok(res.body);
        }
    }

    pub fn cookie_value(&self, name: String) -> Option<String> {
        self.inner.lock().unwrap().cookie_value(&name)
    }

    pub fn cookie_header_string(&self) -> String {
        self.inner.lock().unwrap().cookie_header_string()
    }

    pub fn is_logged_in(&self) -> bool {
        self.inner.lock().unwrap().jar.iter().any(|(k, _)| k.name == "SUB")
    }

    /// cookie 罐快照（含域名，保序）
    pub fn jar_snapshot(&self) -> Vec<CookieEntry> {
        self.inner
            .lock()
            .unwrap()
            .jar
            .iter()
            .map(|(k, v)| CookieEntry {
                domain: k.domain.clone(),
                name: k.name.clone(),
                value: v.clone(),
            })
            .collect()
    }

    /// 确保拿到 CSRF 令牌（写操作前补一次主页访问）
    pub fn ensure_xsrf(&self) -> Result<(), WeiboError> {
        if self.cookie_value("XSRF-TOKEN".to_string()).is_some() {
            return Ok(());
        }
        // 失败不致命（对应 Kotlin 的 runCatching）
        let _ = self.get(format!("{HOST_WEIBO}/"), None, false);
        Ok(())
    }

    /// 保存 cookie（TSV：domain \t path \t name \t value）
    pub fn save_cookies(&self, path: String) -> Result<(), WeiboError> {
        let inner = self.inner.lock().unwrap();
        let lines: Vec<String> = inner
            .jar
            .iter()
            .map(|(k, v)| format!("{}\t/\t{}\t{}", k.domain, k.name, v))
            .collect();
        if let Some(parent) = std::path::Path::new(&path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::write(&path, lines.join("\n"))
            .map_err(|e| WeiboError::http(format!("save cookies: {e}")))
    }

    /// 从文件恢复 cookie（兼容 Netscape 与 TSV 两种格式）
    pub fn load_cookies(&self, path: String) -> Result<(), WeiboError> {
        let Ok(content) = std::fs::read_to_string(&path) else {
            return Ok(()); // 文件不存在：静默返回，对应 Kotlin 的 if (!exists) return
        };
        let mut inner = self.inner.lock().unwrap();
        for line0 in content.lines() {
            let mut line = line0.trim().to_string();
            if line.is_empty() {
                continue;
            }
            if let Some(rest) = line.strip_prefix("#HttpOnly_") {
                line = rest.to_string();
            } else if line.starts_with('#') {
                continue;
            }
            let p: Vec<&str> = line.split('\t').collect();
            if p.len() >= 7 {
                inner.set(
                    CookieKey { domain: p[0].to_string(), name: p[5].to_string() },
                    p[6].to_string(),
                );
            } else if p.len() >= 4 {
                inner.set(
                    CookieKey { domain: p[0].to_string(), name: p[2].to_string() },
                    p[3].to_string(),
                );
            }
        }
        Ok(())
    }
}

impl WeiboHttp {
    /// 相对 Location 基于当前 URL 解析
    fn resolve(base: &str, location: &str) -> Result<String, WeiboError> {
        let b = url::Url::parse(base).map_err(|e| WeiboError::protocol(format!("bad url {base}: {e}")))?;
        b.join(location)
            .map(|u| u.to_string())
            .map_err(|e| WeiboError::protocol(format!("bad location {location}: {e}")))
    }

    /// 一次「不跟随重定向」的请求 + 吸收 cookie
    fn raw(
        &self,
        url: &str,
        method: &str,
        body: Option<&str>,
        referer: Option<&str>,
        ajax: bool,
    ) -> Result<Res, WeiboError> {
        let parsed = url::Url::parse(url).map_err(|e| WeiboError::protocol(format!("bad url {url}: {e}")))?;
        let host = parsed.host_str().unwrap_or("").to_string();

        let mut headers: HashMap<String, String> = HashMap::new();
        let (ua, cookie_hdr, xsrf) = {
            let inner = self.inner.lock().unwrap();
            (
                inner.ua.clone(),
                inner.cookie_header(&host),
                inner.cookie_value("XSRF-TOKEN"),
            )
        };

        headers.insert("User-Agent".into(), ua);
        headers.insert("Accept-Language".into(), "zh-CN,zh;q=0.9".into());
        headers.insert(
            "Accept".into(),
            if ajax {
                "application/json, text/plain, */*".into()
            } else {
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8".into()
            },
        );
        if !cookie_hdr.is_empty() {
            headers.insert("Cookie".into(), cookie_hdr);
        }
        if let Some(r) = referer {
            headers.insert("Referer".into(), r.to_string());
        }
        if ajax {
            headers.insert("X-Requested-With".into(), "XMLHttpRequest".into());
        }
        // 写接口要 CSRF 双提交：cookie `XSRF-TOKEN` + 请求头 `X-XSRF-TOKEN`
        if let Some(x) = xsrf {
            if !x.is_empty() {
                headers.insert("X-XSRF-TOKEN".into(), x);
            }
        }
        if body.is_some() {
            headers.insert(
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            );
        }

        let resp = self.engine.execute(RawRequest {
            url: url.to_string(),
            method: method.to_string(),
            headers,
            body: body.map(|b| b.as_bytes().to_vec()),
        })?;

        self.inner.lock().unwrap().absorb(&host, &resp);

        Ok(Res {
            status: resp.status,
            location: resp.header("Location"),
            body: resp.body_text(),
        })
    }
}

/// 表单 URL 编码（`application/x-www-form-urlencoded`：空格 → `+`）
pub fn enc(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}

#[cfg_attr(feature = "uniffi-ffi", uniffi::export)]
pub fn weibo_url_encode(s: String) -> String {
    enc(&s)
}

// ------------------------------------------------------------------
// 测试
// ------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// 脚本化引擎：按顺序返回预设响应，并记录收到的每一个请求
    struct ScriptedEngine {
        script: Mutex<VecDeque<RawResponse>>,
        log: Mutex<Vec<RawRequest>>,
    }

    impl ScriptedEngine {
        fn new(responses: Vec<RawResponse>) -> Arc<Self> {
            Arc::new(Self {
                script: Mutex::new(responses.into()),
                log: Mutex::new(Vec::new()),
            })
        }
        fn requests(&self) -> Vec<RawRequest> {
            self.log.lock().unwrap().clone()
        }
    }

    impl HttpEngine for ScriptedEngine {
        fn execute(&self, request: RawRequest) -> Result<RawResponse, WeiboError> {
            self.log.lock().unwrap().push(request);
            let mut s = self.script.lock().unwrap();
            Ok(s.pop_front().unwrap_or(RawResponse {
                status: 200,
                headers: HashMap::new(),
                body: Vec::new(),
            }))
        }
    }

    fn mk(status: u16, headers: Vec<(&str, Vec<&str>)>, body: &str) -> RawResponse {
        let mut h: HashMap<String, Vec<String>> = HashMap::new();
        for (k, vs) in headers {
            h.insert(k.to_string(), vs.iter().map(|s| s.to_string()).collect());
        }
        RawResponse {
            status,
            headers: h,
            body: body.as_bytes().to_vec(),
        }
    }

    fn redirect(location: &str, set_cookie: Option<&str>) -> RawResponse {
        let mut headers = vec![("Location", vec![location])];
        if let Some(c) = set_cookie {
            headers.push(("Set-Cookie", vec![c]));
        }
        mk(302, headers, "")
    }

    // ---- 1. 多域同名 SUB：这正是当初把 Kotlin 版卡住的那个 bug ----

    #[test]
    fn multi_domain_sub_must_not_overwrite() {
        let engine = ScriptedEngine::new(vec![
            redirect(
                "https://passport.weibo.com/next",
                Some("SUB=_A; domain=.weibo.com; path=/"),
            ),
            redirect(
                "https://login.sina.com.cn/next",
                Some("SUB=_B; domain=.sina.com.cn; path=/"),
            ),
            redirect(
                "https://passport.sina.cn/next",
                Some("SUB=_C; domain=.sina.cn; path=/"),
            ),
            redirect(
                "https://m.weibo.cn/final",
                Some("SUB=_D; domain=.weibo.cn; path=/"),
            ),
            mk(200, vec![], "DONE"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        let body = http
            .get("https://passport.weibo.com/sso/signin".into(), None, false)
            .unwrap();

        assert_eq!(body, "DONE");
        let jar = http.jar_snapshot();
        assert_eq!(jar.len(), 4, "四个域名应各保留一条 SUB，而不是互相覆盖");

        let val = |d: &str| {
            jar.iter()
                .find(|e| e.domain == d)
                .map(|e| e.value.clone())
        };
        assert_eq!(val(".weibo.com").as_deref(), Some("_A"));
        assert_eq!(val(".sina.com.cn").as_deref(), Some("_B"));
        assert_eq!(val(".sina.cn").as_deref(), Some("_C"));
        assert_eq!(val(".weibo.cn").as_deref(), Some("_D"));
    }

    // ---- 2. 域名匹配：请求只带该域（含子域）的 cookie ----

    #[test]
    fn domain_matching_sends_only_related_cookies() {
        let engine = ScriptedEngine::new(vec![
            mk(
                200,
                vec![(
                    "Set-Cookie",
                    vec!["SUB=_W; domain=.weibo.com; path=/", "SUB2=_M; domain=.weibo.cn; path=/"],
                )],
                "ok",
            ),
            mk(200, vec![], "ok"),
            mk(200, vec![], "ok"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);

        http.get("https://weibo.com/".into(), None, false).unwrap();
        http.get("https://api.weibo.com/2/x".into(), None, false).unwrap(); // 子域
        http.get("https://m.weibo.cn/y".into(), None, false).unwrap();

        let reqs = engine.requests();
        let cookie_of = |i: usize| reqs[i].headers.get("Cookie").cloned().unwrap_or_default();

        assert!(cookie_of(1).contains("SUB=_W"), "weibo.com 的子域应收到 .weibo.com 的 cookie");
        assert!(cookie_of(2).contains("SUB2=_M"), "weibo.cn 应收到 .weibo.cn 的 cookie");
        assert!(!cookie_of(2).contains("SUB=_W"), "weibo.cn 不应收到 .weibo.com 的 cookie");
    }

    // ---- 3. 删除语义 ----

    #[test]
    fn cookie_deletion_semantics() {
        let engine = ScriptedEngine::new(vec![
            mk(
                200,
                vec![(
                    "Set-Cookie",
                    vec!["A=1; domain=.weibo.com; path=/", "B=1; domain=.weibo.com; path=/"],
                )],
                "ok",
            ),
            // A: value=deleted / B: max-age=0
            mk(
                200,
                vec![(
                    "Set-Cookie",
                    vec![
                        "A=deleted; domain=.weibo.com; path=/",
                        "B=1; domain=.weibo.com; path=/; max-age=0",
                    ],
                )],
                "ok",
            ),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);

        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert_eq!(http.jar_snapshot().len(), 2);

        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert_eq!(http.jar_snapshot().len(), 0, "deleted 与 max-age=0 都应删除");
    }

    #[test]
    fn cookie_deletion_by_expires_1970() {
        let engine = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["S=1; domain=.weibo.com; path=/"])], "ok"),
            mk(
                200,
                vec![(
                    "Set-Cookie",
                    vec!["S=; domain=.weibo.com; path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT"],
                )],
                "ok",
            ),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert_eq!(http.jar_snapshot().len(), 1);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert_eq!(http.jar_snapshot().len(), 0);
    }

    // ---- 4. 同名 cookie 在不同域下共存（不互相覆盖） ----

    #[test]
    fn same_name_different_domain_coexist() {
        let engine = ScriptedEngine::new(vec![mk(
            200,
            vec![(
                "Set-Cookie",
                vec![
                    "SUB=a; domain=.weibo.com; path=/",
                    "SUB=b; domain=.weibo.cn; path=/",
                ],
            )],
            "ok",
        )]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        let jar = http.jar_snapshot();
        assert_eq!(jar.len(), 2);
        // cookie_value 取「第一个」，即先插入的 .weibo.com
        assert_eq!(http.cookie_value("SUB".into()).as_deref(), Some("a"));
    }

    // ---- 5. 原地更新不改变顺序 ----

    #[test]
    fn update_in_place_keeps_order() {
        let engine = ScriptedEngine::new(vec![
            mk(
                200,
                vec![("Set-Cookie", vec!["A=1; domain=.weibo.com; path=/", "B=2; domain=.weibo.com; path=/"])],
                "ok",
            ),
            mk(200, vec![("Set-Cookie", vec!["A=9; domain=.weibo.com; path=/"])], "ok"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        http.get("https://weibo.com/".into(), None, false).unwrap();
        // A 更新为新值但仍排在 B 前面
        assert_eq!(http.cookie_header_string(), "A=9; B=2");
    }

    // ---- 6. CSRF 双提交 ----

    #[test]
    fn csrf_double_submit_header() {
        let engine = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["XSRF-TOKEN=tok123; domain=.weibo.com; path=/"])], "ok"),
            mk(200, vec![], "ok"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        http.get("https://weibo.com/ajax/x".into(), Some("https://weibo.com/".into()), true).unwrap();

        let reqs = engine.requests();
        assert_eq!(
            reqs[1].headers.get("X-XSRF-TOKEN").map(|s| s.as_str()),
            Some("tok123"),
            "写接口必须带 X-XSRF-TOKEN 头"
        );
        assert_eq!(
            reqs[1].headers.get("X-Requested-With").map(|s| s.as_str()),
            Some("XMLHttpRequest")
        );
        assert!(reqs[1].headers.get("Cookie").unwrap().contains("XSRF-TOKEN=tok123"));
    }

    #[test]
    fn ensure_xsrf_fetches_homepage_once() {
        let engine = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["XSRF-TOKEN=t1; domain=.weibo.com; path=/"])], "home"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.ensure_xsrf().unwrap();
        http.ensure_xsrf().unwrap(); // 已有则不重复请求
        assert_eq!(engine.requests().len(), 1, "已拿到令牌后不应再请求主页");
    }

    // ---- 7. 重定向跳数上限 ----

    #[test]
    fn redirect_hop_limit_is_10() {
        let mut responses = Vec::new();
        for i in 0..12 {
            responses.push(redirect(&format!("https://weibo.com/step{i}"), None));
        }
        responses.push(mk(200, vec![], "END"));

        let engine = ScriptedEngine::new(responses);
        let http = WeiboHttp::new(engine.clone(), None);
        let body = http.get("https://weibo.com/start".into(), None, false).unwrap();

        // 原始请求 + 10 跳 = 11 次，第 11 跳后放弃跟随，返回该跳的响应体（空）
        assert_eq!(engine.requests().len(), 11);
        assert_eq!(body, "", "到达上限后返回当前跳的响应体，而不是继续跟到 END");
    }

    // ---- 8. POST 重定向后不再带 body ----

    #[test]
    fn post_redirect_drops_body() {
        let engine = ScriptedEngine::new(vec![
            redirect("https://weibo.com/next", None),
            mk(200, vec![], "OK"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        let mut form = HashMap::new();
        form.insert("a".to_string(), "1".to_string());
        let body = http
            .post_form("https://weibo.com/post".into(), form, None, false)
            .unwrap();

        assert_eq!(body, "OK");
        let reqs = engine.requests();
        assert_eq!(reqs[0].body.as_deref(), Some(b"a=1".as_ref()));
        assert!(reqs[1].body.is_none(), "跳转后不应再带 body");
    }

    // ---- 9. 表单编码 ----

    #[test]
    fn form_encoding_matches_java_urlencoder() {
        assert_eq!(enc("hello world"), "hello+world"); // 空格 → +（不是 %20）
        assert_eq!(enc("a&b=c"), "a%26b%3Dc");
        assert_eq!(enc("中文"), "%E4%B8%AD%E6%96%87");
        assert_eq!(enc("a-b_c.d*e"), "a-b_c.d*e"); // 这些字符不转义
        assert_eq!(enc("+/"), "%2B%2F");
    }

    // ---- 10. 登录态判定 ----

    #[test]
    fn is_logged_in_requires_sub() {
        let engine = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["OTHER=1; domain=.weibo.com; path=/"])], "ok"),
            mk(200, vec![("Set-Cookie", vec!["SUB=x; domain=.weibo.com; path=/"])], "ok"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        assert!(!http.is_logged_in());
        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert!(!http.is_logged_in());
        http.get("https://weibo.com/".into(), None, false).unwrap();
        assert!(http.is_logged_in());
    }

    // ---- 11. cookie 文件读写往返 ----

    #[test]
    fn cookie_save_load_roundtrip() {
        let engine = ScriptedEngine::new(vec![mk(
            200,
            vec![(
                "Set-Cookie",
                vec!["SUB=v1; domain=.weibo.com; path=/", "SUB2=v2; domain=.weibo.cn; path=/"],
            )],
            "ok",
        )]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        let before = http.cookie_header_string();

        let dir = std::env::temp_dir().join("weibo-poc-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("cookies.tsv");
        let p = path.to_string_lossy().to_string();
        http.save_cookies(p.clone()).unwrap();

        // 新实例加载后应完全一致
        let engine2 = ScriptedEngine::new(vec![]);
        let http2 = WeiboHttp::new(engine2, None);
        http2.load_cookies(p).unwrap();
        assert_eq!(http2.cookie_header_string(), before);
        assert_eq!(http2.jar_snapshot().len(), 2);

        let _ = std::fs::remove_file(&path);
    }

    // ---- 12. Netscape 格式兼容 ----

    #[test]
    fn load_netscape_format() {
        let dir = std::env::temp_dir().join("weibo-poc-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("netscape.txt");
        std::fs::write(
            &path,
            "# Netscape HTTP Cookie File\n.weibo.com\tTRUE\t/\tTRUE\t0\tSUB\tnetscape_value\n",
        )
        .unwrap();

        let engine = ScriptedEngine::new(vec![]);
        let http = WeiboHttp::new(engine, None);
        http.load_cookies(path.to_string_lossy().to_string()).unwrap();

        assert_eq!(http.cookie_value("SUB".into()).as_deref(), Some("netscape_value"));
        assert!(http.is_logged_in());
        let _ = std::fs::remove_file(&path);
    }

    // ---- 13. 未带 domain 属性时回落到请求 host ----

    #[test]
    fn cookie_without_domain_attribute_falls_back_to_host() {
        let engine = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["NOVDOM=1; path=/"])], "ok"),
            mk(200, vec![], "ok"),
        ]);
        let http = WeiboHttp::new(engine.clone(), None);
        http.get("https://weibo.com/".into(), None, false).unwrap();
        http.get("https://weibo.com/x".into(), None, false).unwrap();

        assert_eq!(http.jar_snapshot()[0].domain, "weibo.com");
        assert!(engine.requests()[1]
            .headers
            .get("Cookie")
            .unwrap()
            .contains("NOVDOM=1"));
        // 换个域就不该带
        let engine2 = ScriptedEngine::new(vec![
            mk(200, vec![("Set-Cookie", vec!["NOVDOM=1; path=/"])], "ok"),
            mk(200, vec![], "ok"),
        ]);
        let http2 = WeiboHttp::new(engine2.clone(), None);
        http2.get("https://weibo.com/".into(), None, false).unwrap();
        http2.get("https://example.com/x".into(), None, false).unwrap();
        assert!(engine2.requests()[1].headers.get("Cookie").is_none());
    }
}
