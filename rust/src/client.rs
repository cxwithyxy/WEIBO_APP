//! 微博客户端门面（Rust 移植）
//!
//! 对应原 Kotlin `WeiboClient.kt`。接口层全部集中在此，
//! 微博前端一改只动这里（隔离变更风险）。

use crate::auth::WeiboAuth;
use crate::http::{enc, HttpEngine, WeiboError, WeiboHttp, HOST_WEIBO};
use crate::models::*;
use std::sync::{Arc, Mutex};

#[derive(uniffi::Object)]
pub struct WeiboClient {
    http: Arc<WeiboHttp>,
    /// 与原 Kotlin 一致：auth 只建一次，共用同一个 cookie 罐
    auth: Arc<WeiboAuth>,
    uid: Mutex<Option<String>>,
}

#[uniffi::export]
impl WeiboClient {
    #[uniffi::constructor]
    pub fn new(engine: Arc<dyn HttpEngine>) -> Arc<Self> {
        let http = WeiboHttp::new(engine, None);
        let auth = WeiboAuth::new(http.clone());
        Arc::new(Self {
            http,
            auth,
            uid: Mutex::new(None),
        })
    }

    /// 扫码登录（与原 Kotlin `client.auth` 对应）
    pub fn auth(&self) -> Arc<WeiboAuth> {
        self.auth.clone()
    }

    pub fn is_logged_in(&self) -> bool {
        self.http.is_logged_in()
    }

    pub fn uid(&self) -> Option<String> {
        self.uid.lock().unwrap().clone()
    }

    pub fn http(&self) -> Arc<WeiboHttp> {
        self.http.clone()
    }

    // ---------------- 会话 ----------------

    /// 从 cookie 文件恢复会话；成功则填充 uid
    pub fn restore(&self, cookie_file: String) -> bool {
        if let Err(e) = self.http.load_cookies(cookie_file) {
            let _ = e;
            return false;
        }
        if !self.http.is_logged_in() {
            return false;
        }
        match self.fetch_uid() {
            Ok(Some(u)) => {
                *self.uid.lock().unwrap() = Some(u);
                true
            }
            _ => false,
        }
    }

    pub fn save(&self, cookie_file: String) -> Result<(), WeiboError> {
        self.http.save_cookies(cookie_file)
    }

    /// 从首页 HTML 里解析自己的 uid
    pub fn fetch_uid(&self) -> Result<Option<String>, WeiboError> {
        let html = self.http.get(format!("{HOST_WEIBO}/"), None, false)?;
        Ok(parse_uid(&html))
    }

    // ---------------- 接口 ----------------

    /// 首页时间线一页。
    ///
    /// 翻页语义（实测）：`since_id` = 「给我比这个游标更旧的」；
    /// 把返回的 `next_cursor`（响应里的 max_id_str）传回 `since_id` 即可续拉。
    pub fn home_timeline_page(
        &self,
        since_id: String,
        count: u32,
    ) -> Result<TimelinePage, WeiboError> {
        let raw = self.home_timeline_page_raw(since_id, count)?;
        Ok(TimelinePage {
            statuses: raw.statuses,
            next_cursor: raw.next_cursor,
        })
    }

    /// 同 home_timeline_page，但同时返回**原始响应文本**（用于本地缓存）
    pub fn home_timeline_page_raw(
        &self,
        since_id: String,
        count: u32,
    ) -> Result<TimelineRaw, WeiboError> {
        // 服务端要求 `since_id` 必须是 long；传**空串**会直接报
        //   parameter (since_id)'s value invalid, expect (long[...]), but get ()
        // 注意：不能省略这个参数（省了会被当成缺参），第一页要显式给 0。
        // 真机验证时踩到过。
        let since_id = if since_id.trim().is_empty() {
            "0".to_string()
        } else {
            since_id
        };
        let raw = self.get_json(format!(
            "/ajax/feed/unreadfriendstimeline?since_id={since_id}&refresh=1&count={count}"
        ))?;
        let r: TimelineResp = self.parse(&raw)?;
        self.check_ok(r.ok, r.message.as_deref(), "首页时间线")?;
        Ok(TimelineRaw {
            raw,
            statuses: r.statuses.unwrap_or_default(),
            next_cursor: r.max_id_str.or(r.max_id),
        })
    }

    /// 把缓存下来的响应原文重新解析成微博列表（与网络路径**同一套解析**）
    pub fn parse_timeline_raw(&self, raw: String) -> Vec<Status> {
        serde_json::from_str::<TimelineResp>(&raw)
            .ok()
            .and_then(|r| r.statuses)
            .unwrap_or_default()
    }

    /// 某个用户的微博列表。`page=N` 翻页零重叠。
    pub fn user_timeline_page_raw(
        &self,
        uid: String,
        page: u32,
    ) -> Result<TimelineRaw, WeiboError> {
        let raw = self.get_json(format!("/ajax/statuses/mymblog?uid={uid}&page={page}&feature=0"))?;
        let r: MyBlogResp = self.parse(&raw)?;
        self.check_ok(r.ok, r.message.as_deref(), "用户微博")?;
        Ok(TimelineRaw {
            raw,
            statuses: r.data.and_then(|d| d.list).unwrap_or_default(),
            next_cursor: Some((page + 1).to_string()),
        })
    }

    pub fn user_info(&self, uid: String) -> Result<Option<User>, WeiboError> {
        self.profile(Some(uid))
    }

    /// 取长文全文（服务端会把长文截断）
    pub fn long_text(&self, id: String) -> Result<Option<String>, WeiboError> {
        let raw = self.get_json(format!("/ajax/statuses/longtext?id={id}"))?;
        let r: LongTextResp = self.parse(&raw)?;
        self.check_ok(r.ok, None, "长文")?;
        let Some(d) = r.data else { return Ok(None) };
        let t = d
            .long_text_content_raw
            .filter(|s| !s.trim().is_empty())
            .or(d.long_text_content);
        Ok(t.map(|s| crate::models::weibo_strip_tags(s).trim().to_string())
            .filter(|s| !s.is_empty()))
    }

    /// 首页时间线（关注的人）—— 只要第一页时用这个
    pub fn home_timeline(&self, count: u32, since_id: String) -> Result<Vec<Status>, WeiboError> {
        Ok(self.home_timeline_page(since_id, count)?.statuses)
    }

    /// 「我的关注」时间线（纯关注，时间序，无推荐/广告）。
    ///
    /// ⚠️ 实测：该端点 `since_id` **翻页无效**（第二页与第一页 100% 重叠），
    /// 必须用 `page=N`。所以这里的游标是「下一页页码」。
    pub fn following_timeline_page_raw(
        &self,
        page: u32,
        count: u32,
    ) -> Result<TimelineRaw, WeiboError> {
        let raw = self.get_json(format!("/ajax/feed/friendstimeline?page={page}&count={count}"))?;
        let r: TimelineResp = self.parse(&raw)?;
        self.check_ok(r.ok, r.message.as_deref(), "关注时间线")?;
        Ok(TimelineRaw {
            raw,
            statuses: r.statuses.unwrap_or_default(),
            next_cursor: Some((page + 1).to_string()),
        })
    }

    pub fn following_timeline(&self, count: u32) -> Result<Vec<Status>, WeiboError> {
        Ok(self.following_timeline_page_raw(1, count)?.statuses)
    }

    /// 某个用户的微博列表（默认自己）
    pub fn my_blog(&self, uid: Option<String>, page: u32) -> Result<Vec<Status>, WeiboError> {
        let u = uid.or_else(|| self.uid()).ok_or_else(|| {
            WeiboError::protocol("未知 uid，请先 restore/whoami")
        })?;
        let json = self.get_json(format!("/ajax/statuses/mymblog?uid={u}&page={page}&feature=0"))?;
        let r: MyBlogResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "微博列表")?;
        Ok(r.data.and_then(|d| d.list).unwrap_or_default())
    }

    /// 用户资料
    pub fn profile(&self, uid: Option<String>) -> Result<Option<User>, WeiboError> {
        let u = uid
            .filter(|s| !s.is_empty())
            .or_else(|| self.uid())
            .ok_or_else(|| WeiboError::protocol("需要 uid"))?;
        let json = self.get_json(format!("/ajax/profile/info?uid={u}"))?;
        let r: ProfileInfoResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "用户资料")?;
        Ok(r.data.and_then(|d| d.user))
    }

    /// 关注列表
    pub fn following(&self, uid: Option<String>) -> Result<Vec<User>, WeiboError> {
        let u = uid
            .filter(|s| !s.is_empty())
            .or_else(|| self.uid())
            .ok_or_else(|| WeiboError::protocol("需要 uid"))?;
        let json = self.get_json(format!("/ajax/profile/followContent?uid={u}"))?;
        let r: FollowResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "关注列表")?;
        Ok(r.data
            .and_then(|d| d.follows)
            .and_then(|f| f.users)
            .unwrap_or_default())
    }

    /// 热搜榜（公开接口，不需要登录）
    pub fn hot_search(&self) -> Result<Vec<HotItem>, WeiboError> {
        let json = self.get_json("/ajax/side/hotSearch".to_string())?;
        let r: HotResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "热搜")?;
        Ok(r.data.and_then(|d| d.realtime).unwrap_or_default())
    }

    /// 热搜榜单详情
    pub fn hot_band(&self, band_id: u32, count: u32) -> Result<Vec<HotBandItem>, WeiboError> {
        let json = self.get_json(format!("/ajax/statuses/hot_band?band_id={band_id}&count={count}"))?;
        let r: HotBandResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "热搜榜单")?;
        Ok(r.data.and_then(|d| d.band_list).unwrap_or_default())
    }

    /// 单条微博详情。注意：`statuses/show` 直接返回微博对象（无 `ok` 信封）。
    pub fn status_detail(&self, mid: String) -> Result<Status, WeiboError> {
        let json = self.get_json(format!("/ajax/statuses/show?id={mid}"))?;
        serde_json::from_str::<Status>(&json)
            .map_err(|e| WeiboError::protocol(format!("详情解析失败: {e}（{}）", &json[..json.len().min(120)])))
    }

    /// 评论列表。
    ///
    /// ⚠️ 实测：`count` 被忽略（固定 20 条）；`flow=0` 按热度**翻页无效**；
    /// `flow=1` 按时间可正常翻页。需要翻页请用 `flow = 1`。
    pub fn comments(
        &self,
        mid: String,
        count: u32,
        max_id: i64,
        flow: u32,
    ) -> Result<Vec<Comment>, WeiboError> {
        Ok(self.comments_page(mid, count, max_id, flow)?.comments)
    }

    /// 评论一页（带下一页游标）
    pub fn comments_page(
        &self,
        mid: String,
        count: u32,
        max_id: i64,
        flow: u32,
    ) -> Result<CommentPage, WeiboError> {
        let json = self.get_json(format!(
            "/ajax/statuses/buildComments?is_reload=1&id={mid}&is_show_bulletin=2\
             &is_mix=0&count={count}&max_id={max_id}&flow={flow}"
        ))?;
        let r: CommentsResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "评论")?;
        Ok(CommentPage {
            comments: r.data.unwrap_or_default(),
            next_max_id: r.max_id,
            total_number: r.total_number,
        })
    }

    /// 转发列表
    pub fn reposts(&self, mid: String, page: u32) -> Result<Vec<Status>, WeiboError> {
        let json = self.get_json(format!("/ajax/statuses/repostTimeline?id={mid}&page={page}"))?;
        let r: RepostResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "转发列表")?;
        Ok(r.data.unwrap_or_default())
    }

    /// 搜索微博
    pub fn search(&self, q: String, count: u32, page: u32) -> Result<Vec<Status>, WeiboError> {
        let json = self.get_json(format!("/ajax/statuses/search?q={}&count={count}&page={page}", enc(&q)))?;
        let r: SearchResp = self.parse(&json)?;
        self.check_ok(r.ok, r.message.as_deref(), "搜索")?;
        Ok(r.statuses.unwrap_or_default())
    }

    // ==================== 互动（写操作） ====================

    /// 点赞
    pub fn set_like(&self, id: String) -> Result<(), WeiboError> {
        let r = self.mutation("/ajax/statuses/setLike", vec![("id", id.clone())], &format!("https://weibo.com/detail/{id}"))?;
        self.check_mutation(&r, "点赞")
    }

    /// 取消赞
    pub fn cancel_like(&self, id: String) -> Result<(), WeiboError> {
        let r = self.mutation("/ajax/statuses/cancelLike", vec![("id", id.clone())], &format!("https://weibo.com/detail/{id}"))?;
        self.check_mutation(&r, "取消赞")
    }

    /// 转发
    pub fn repost(
        &self,
        id: String,
        text: String,
        also_comment: bool,
        pic_id: String,
    ) -> Result<(), WeiboError> {
        let comment = if text.trim().is_empty() { "转发微博".to_string() } else { text.trim().to_string() };
        let r = self.mutation(
            "/ajax/statuses/repost",
            vec![
                ("id", id.clone()),
                ("comment", comment),
                ("is_comment", if also_comment { "1".into() } else { "0".into() }),
                ("pic_id", pic_id),
            ],
            &format!("https://weibo.com/detail/{id}"),
        )?;
        self.check_mutation(&r, "转发")
    }

    /// 发评论；`reply_to_cid` 非空时为回复某条评论
    pub fn comment(
        &self,
        id: String,
        text: String,
        reply_to_cid: Option<String>,
        also_repost: bool,
        pic_id: String,
    ) -> Result<(), WeiboError> {
        let mut form: Vec<(&str, String)> = vec![
            ("id", id.clone()),
            ("comment", text),
            ("pic_id", pic_id),
            ("is_repost", if also_repost { "1".into() } else { "0".into() }),
            ("comment_ori", "0".into()),
            ("is_comment", "0".into()),
            ("fp", String::new()),
        ];
        let cid = reply_to_cid.filter(|s| !s.trim().is_empty());
        let path = if cid.is_some() {
            if let Some(c) = cid {
                form.push(("cid", c));
            }
            "/ajax/comments/reply"
        } else {
            "/ajax/comments/create"
        };
        let r = self.mutation(path, form, &format!("https://weibo.com/detail/{id}"))?;
        self.check_mutation(&r, "评论")
    }

    /// 收藏 / 取消收藏
    pub fn favorite(&self, id: String, on: bool) -> Result<(), WeiboError> {
        let path = if on {
            "/ajax/statuses/createFavorites"
        } else {
            "/ajax/statuses/destoryFavorites"
        };
        let r = self.mutation(path, vec![("id", id)], "https://weibo.com/fav")?;
        self.check_mutation(&r, if on { "收藏" } else { "取消收藏" })
    }

    /// 删除自己发的微博
    pub fn destroy_status(&self, id: String) -> Result<(), WeiboError> {
        let r = self.mutation("/ajax/statuses/destroy", vec![("id", id.clone())], &format!("https://weibo.com/detail/{id}"))?;
        self.check_mutation(&r, "删除微博")
    }

    /// 发微博（纯文字）。返回新微博的 idstr。
    ///
    /// 走 **weibo.com 桌面端**接口，复用现有会话 + CSRF。
    /// `visible`: 0=公开 1=仅关注 6=仅自己
    pub fn post_status(&self, content: String, visible: u32) -> Result<String, WeiboError> {
        let text = content.trim().to_string();
        if text.is_empty() {
            return Err(WeiboError::protocol("微博内容不能为空"));
        }
        let raw = self.mutation(
            "/ajax/statuses/update",
            vec![("content", text), ("visible", visible.to_string())],
            "https://weibo.com/",
        )?;
        let obj: serde_json::Value = serde_json::from_str(&raw).map_err(|_| {
            WeiboError::protocol(format!("发微博失败：响应无法解析（{}）", &raw[..raw.len().min(120)]))
        })?;
        let ok = obj.get("ok").and_then(|v| v.as_i64());
        let data = obj.get("data");
        if data.is_none() || (ok.is_some() && ok != Some(1)) {
            let msg = obj
                .get("msg")
                .or_else(|| obj.get("message"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            return Err(WeiboError::protocol(format!("发微博失败: ok={} {msg}", fmt_ok(ok))));
        }
        let d = data.unwrap();
        Ok(d.get("idstr")
            .or_else(|| d.get("id"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string())
    }
}

// ------------------------------------------------------------------ 内部

impl WeiboClient {
    /// 微博 /ajax/* 强制校验 Referer，缺失会 403
    fn referer(&self) -> String {
        match self.uid() {
            Some(u) => format!("{HOST_WEIBO}/u/{u}"),
            None => format!("{HOST_WEIBO}/"),
        }
    }

    fn get_json(&self, path: String) -> Result<String, WeiboError> {
        self.http
            .get(format!("{HOST_WEIBO}{path}"), Some(self.referer()), true)
    }

    /// 解析响应 JSON。
    ///
    /// 之前这里用 `unwrap_or_default()`，把 serde 的解析错误**静默吞掉**，
    /// 对外只表现为「响应没有 ok 字段」，极难排查（真的踩过一次）。
    /// 现在把原始错误暴露出来（与原 Kotlin 抛出 JsonSyntaxException 的行为一致）。
    fn parse<T: serde::de::DeserializeOwned>(&self, raw: &str) -> Result<T, WeiboError> {
        serde_json::from_str(raw).map_err(|e| {
            let head: String = raw.chars().take(160).collect();
            WeiboError::protocol(format!(
                "响应解析失败: {e}（响应 {} 字节，开头：{head}）",
                raw.len()
            ))
        })
    }

    fn check_ok(&self, ok: Option<i32>, message: Option<&str>, ctx: &str) -> Result<(), WeiboError> {
        if ok != Some(1) {
            let hint = if ok.is_none() {
                "（响应无 ok 字段，通常是被拦截或未登录）"
            } else {
                ""
            };
            return Err(WeiboError::protocol(format!(
                "{ctx} 失败: ok={} message={}{hint}",
                fmt_ok(ok),
                message.unwrap_or("")
            )));
        }
        Ok(())
    }

    fn mutation(
        &self,
        path: &str,
        form: Vec<(&str, String)>,
        referer: &str,
    ) -> Result<String, WeiboError> {
        self.http.ensure_xsrf()?;
        let mut map = std::collections::HashMap::new();
        for (k, v) in form {
            map.insert(k.to_string(), v);
        }
        self.http
            .post_form(format!("{HOST_WEIBO}{path}"), map, Some(referer.to_string()), true)
    }

    /// 写操作统一校验：ok 存在且非 1 才算失败（部分接口不返回 ok）
    fn check_mutation(&self, raw: &str, what: &str) -> Result<(), WeiboError> {
        let obj: serde_json::Value = serde_json::from_str(raw).map_err(|_| {
            WeiboError::protocol(format!("{what} 失败：响应无法解析（{}）", &raw[..raw.len().min(120)]))
        })?;
        let ok = obj.get("ok").and_then(|v| v.as_i64());
        if let Some(v) = ok {
            if v != 1 {
                let msg = obj
                    .get("msg")
                    .or_else(|| obj.get("message"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("");
                return Err(WeiboError::protocol(format!("{what} 失败: ok={v} {msg}")));
            }
        }
        Ok(())
    }
}

/// 按 Kotlin 的方式格式化可空整数（`0` / `null`，而非 Rust 的 `Some(0)` / `None`）
fn fmt_ok<T: std::fmt::Display>(v: Option<T>) -> String {
    match v {
        Some(x) => x.to_string(),
        None => "null".to_string(),
    }
}

/// 从首页 HTML 里解析 uid（对应 Kotlin `Regex("\"uid\":(\\d+)")`）
pub fn parse_uid(html: &str) -> Option<String> {
    let key = "\"uid\":";
    let i = html.find(key)?;
    let rest = &html[i + key.len()..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    if digits.is_empty() {
        None
    } else {
        Some(digits)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timeline_ids_accept_numbers() {
        // 微博的 max_id / since_id 实际给的是**数字**（max_id_str 才是字符串）。
        // Gson 会自动把数字转成 String，serde 不会 —— 这里必须宽松处理，
        // 否则整个响应解析失败（线上真的因此挂过“关注时间线”）。
        let json = r#"{"ok":1,"statuses":[],"since_id":123456789,"max_id":987654321,
                       "since_id_str":"123456789","max_id_str":"987654321"}"#;
        let r: TimelineResp = serde_json::from_str(json).unwrap();
        assert_eq!(r.ok, Some(1));
        assert_eq!(r.max_id.as_deref(), Some("987654321"));
        assert_eq!(r.since_id.as_deref(), Some("123456789"));
        assert_eq!(r.max_id_str.as_deref(), Some("987654321"));
    }

    /// 用真实响应抓解析问题（诊断用）
    /// 跑： WEIBO_FIXTURE=/tmp/x.json cargo test parse_real_fixture -- --nocapture
    #[test]
    fn parse_real_fixture() {
        let path = std::env::var("WEIBO_FIXTURE")
            .unwrap_or_else(|_| "/tmp/friendstimeline.json".into());
        let raw = match std::fs::read_to_string(&path) {
            Ok(r) => r,
            Err(_) => return, // 没夹具就跳过
        };
        match serde_json::from_str::<TimelineResp>(&raw) {
            Ok(r) => println!(
                "解析成功: ok={:?} statuses={}",
                r.ok,
                r.statuses.as_ref().map(|s| s.len()).unwrap_or(0)
            ),
            Err(e) => panic!("解析失败 → {e}"),
        }
    }

    #[test]
    fn parse_uid_from_html() {
        let html = r#"<script>{"uid":1738495687,"other":1}</script>"#;
        assert_eq!(parse_uid(html).as_deref(), Some("1738495687"));
        assert_eq!(parse_uid("nothing here"), None);
        assert_eq!(parse_uid(r#""uid":"abc""#), None);
    }

    #[test]
    fn is_ad_polymorphic() {
        let mk = |j: &str| -> Status {
            serde_json::from_str(&format!(r#"{{"isAd":{j}}}"#)).unwrap()
        };
        assert!(mk("true").is_ad_flag());
        assert!(!mk("false").is_ad_flag());
        assert!(mk("1").is_ad_flag());
        assert!(!mk("0").is_ad_flag());
        assert!(mk(r#""true""#).is_ad_flag());
        assert!(mk(r#""TRUE""#).is_ad_flag()); // 忽略大小写
        assert!(mk(r#""1""#).is_ad_flag());
        assert!(!mk(r#""0""#).is_ad_flag());
        assert!(!mk(r#""weird""#).is_ad_flag());
        // 字段缺失
        let s: Status = serde_json::from_str("{}").unwrap();
        assert!(!s.is_ad_flag());
    }

    #[test]
    fn plain_text_prefers_text_raw() {
        let s: Status = serde_json::from_str(r#"{"text_raw":"raw","text":"<b>html</b>"}"#).unwrap();
        assert_eq!(s.plain_text(), "raw");
        let s2: Status = serde_json::from_str(r#"{"text":"<b>html</b> ok"}"#).unwrap();
        assert_eq!(s2.plain_text(), "html ok");
        let s3: Status = serde_json::from_str("{}").unwrap();
        assert_eq!(s3.plain_text(), "");
    }

    #[test]
    fn image_urls_prefer_bmiddle() {
        let json = r#"{
          "pic_ids": ["a", "b", "c"],
          "pic_infos": {
            "a": {"thumbnail": {"url": "t_a"}, "bmiddle": {"url": "m_a"}, "large": {"url": "l_a"}},
            "b": {"thumbnail": {"url": "t_b"}}
          }
        }"#;
        let s: Status = serde_json::from_str(json).unwrap();
        assert_eq!(s.image_urls(), vec!["m_a", "t_b", "https://wx1.sinaimg.cn/wap360/c.jpg"]);
    }
}
