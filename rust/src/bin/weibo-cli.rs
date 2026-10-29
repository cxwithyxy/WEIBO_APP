//! 微博客户端命令行（Rust）
//!
//! 替代原 Kotlin 的 `cli` 模块。会话文件与原先一致：
//!   ~/.weibo-client/cookies.tsv
//!
//! 用法: weibo-cli <命令> [参数]
//!   登录/状态: login | whoami | logout
//!   读:        hot | band | timeline [n] | following [n] | meblog | user <uid>
//!              followed | detail <mid> | comments <mid> [n] | reposts <mid>
//!              search <关键词> | longtext <id> | mylatest
//!              video <mid> | videos [n]
//!   写（需 --yes）:
//!              post <内容> [--private|--followers] | like|unlike <id>
//!              repost <id> [文字] | comment <id> <文字> | fav <id> [--off]
//!              delete <id>
//!
//! 视频（只读，无需 --yes）：
//!   video <mid>      拉单条微博详情，打印 page_info 原文 + 解析出的类型/时长/封面/视频 URL
//!   videos [n]       扫首页（失败退关注流）前 n 条，列出带视频的微博（默认 20）
//!   两者都支持 `--json <文件>`：离线重放一份已保存的接口响应（video 传
//!   `statuses/show` 原文，videos 传时间线原文），走与联网路径**完全相同**的解析代码。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use weibo_core::client::WeiboClient;
use weibo_core::http::{HttpEngine, RawRequest, WeiboError};
use weibo_core::models::{Comment, Status};
use weibo_core::reqwest_engine::ReqwestEngine;

// ------------------------------------------------------------------ 工具

fn cookie_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    let dir = PathBuf::from(home).join(".weibo-client");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("cookies.tsv")
}

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("✗ 错误: {msg}");
    std::process::exit(1);
}

/// 命令行参数里取「非选项」部分并拼成一句话
fn free_text(args: &[String]) -> String {
    args.iter()
        .filter(|a| !a.starts_with("--"))
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
}

/// 取 `--flag value` 形式选项的值
fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

/// 读一份本地保存的接口响应原文（配合 `--json` 离线重放）
fn read_json_file(path: &str) -> Result<String, WeiboError> {
    std::fs::read_to_string(path)
        .map_err(|e| WeiboError::protocol(format!("读取 {path} 失败: {e}")))
}

/// 写操作确认闸门：真实账号会产生效果，必须显式 --yes
fn confirm(args: &[String], what: &str) -> bool {
    if args.iter().any(|a| a == "--yes") {
        return true;
    }
    println!("⚠ {what} 会在你的真实微博账号上生效（对方会收到通知，或内容公开可见）。");
    println!("  确认要执行就加上 --yes，例如：{what} … --yes");
    false
}

// ------------------------------------------------------------------ 打印

fn print_statuses(list: &[Status]) {
    if list.is_empty() {
        println!("(空)");
        return;
    }
    for s in list {
        let name = s
            .user
            .as_ref()
            .and_then(|u| u.screen_name.clone())
            .unwrap_or_else(|| "?".into());
        let text: String = s.plain_text().replace('\n', " ").chars().take(120).collect();
        println!("{}", "─".repeat(60));
        println!(
            "{}  ·  {}   [mid={}]",
            name,
            s.created_at.clone().unwrap_or_default(),
            s.idstr.clone().unwrap_or_default()
        );
        println!("{text}");
        println!(
            "  转发 {}  评论 {}  赞 {}",
            s.reposts_count.unwrap_or(0),
            s.comments_count.unwrap_or(0),
            s.attitudes_count.unwrap_or(0)
        );
    }
}

// ------------------------------------------------------------------ 登录

fn do_login(client: &Arc<WeiboClient>, cookie: &Path) {
    let cookie_s = cookie.to_string_lossy().to_string();
    if client.restore(cookie_s.clone()) {
        println!(
            "✓ 已有有效会话（uid={}），无需重新登录",
            client.uid().unwrap_or_default()
        );
        return;
    }

    // 二维码图片用独立引擎下载（这一步不需要 cookie）
    let qr_path = cookie.with_file_name("qr.png");
    let save_qr = |url: &str| {
        let res = (|| -> Result<(), String> {
            let engine: Arc<dyn HttpEngine> =
                ReqwestEngine::new().map_err(|e| format!("{e:?}"))?;
            let resp = engine
                .execute(RawRequest {
                    url: url.to_string(),
                    method: "GET".into(),
                    headers: std::collections::HashMap::new(),
                    body: None,
                })
                .map_err(|e| format!("{e:?}"))?;
            std::fs::write(&qr_path, &resp.body).map_err(|e| e.to_string())?;
            println!("二维码已保存 → {}", qr_path.display());
            println!("（也可直接用浏览器打开该 URL 扫码）");
            Ok(())
        })();
        if let Err(e) = res {
            eprintln!("  ⚠ 二维码图片保存失败: {e}");
        }
    };

    println!("请用手机微博 App 扫码并确认…\n");

    let mut last = String::new();
    let res = client.auth().login_blocking(
        180,
        2000,
        |qr| save_qr(&qr.image_url),
        |st| {
            let name = format!("{:?}", st.state);
            if name != last {
                println!("  [{name}] {}", st.message.clone().unwrap_or_default());
                last = name;
            }
        },
    );

    match res {
        Ok(true) => {
            if let Err(e) = client.save(cookie_s.clone()) {
                die(format!("保存会话失败: {e:?}"));
            }
            if client.restore(cookie_s) {
                println!("\n✓ 登录成功！uid={}", client.uid().unwrap_or_default());
            } else {
                println!("✗ 已确认但未取得会话 cookie");
            }
        }
        Ok(false) => println!("✗ 登录失败或超时，请重试"),
        Err(e) => println!("✗ 登录出错: {e:?}"),
    }
}

// ------------------------------------------------------------------ 命令分发

fn run_command(
    client: &Arc<WeiboClient>,
    cmd: &str,
    args: &[String],
) -> Result<(), WeiboError> {
    match cmd {
        "whoami" => {
            let u = client
                .profile(None)?
                .ok_or_else(|| WeiboError::protocol("取资料失败"))?;
            println!("uid        : {}", u.idstr.clone().unwrap_or_default());
            println!("昵称       : {}", u.screen_name.clone().unwrap_or_default());
            println!(
                "关注 / 粉丝 : {} / {}",
                u.friends_count.unwrap_or(0),
                u.followers_count.unwrap_or(0)
            );
            println!("微博数     : {}", u.statuses_count.unwrap_or(0));
            println!(
                "认证       : {}",
                if u.verified == Some(true) { "是" } else { "否" }
            );
            if let Some(d) = u.description.clone() {
                if !d.trim().is_empty() {
                    println!("简介       : {d}");
                }
            }
        }

        "hot" => {
            for (i, h) in client.hot_search()?.iter().take(20).enumerate() {
                println!(
                    "{:>2}. {:<32} {}",
                    i + 1,
                    h.word.clone().unwrap_or_default(),
                    h.num.unwrap_or(0)
                );
            }
        }

        "band" => {
            for h in client.hot_band(1, 50)? {
                let tag = h
                    .label_name
                    .clone()
                    .or_else(|| h.icon_desc.clone())
                    .unwrap_or_default();
                println!(
                    "{:>2}. {:<30} {:<10} {}",
                    h.realpos.or(h.rank).unwrap_or(0),
                    h.word.clone().unwrap_or_default(),
                    tag,
                    h.num.unwrap_or(0)
                );
            }
        }

        "timeline" => {
            let n: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(20);
            let list = client.home_timeline(n, "0".into())?;
            println!("首页时间线（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "following" => {
            let n: u32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(20);
            let list = client.following_timeline(n)?;
            println!("关注时间线（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "meblog" => {
            let list = client.my_blog(None, 1)?;
            println!("我的微博（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "user" => {
            let uid = args.get(2).cloned().unwrap_or_default();
            if uid.is_empty() {
                return Err(WeiboError::protocol("用法: user <uid>"));
            }
            let list = client.my_blog(Some(uid.clone()), 1)?;
            println!("用户 {uid} 的微博（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "followed" => {
            let users = client.following(None)?;
            println!("关注（{} 人）\n", users.len());
            for u in users {
                println!(
                    "· {}  ({})",
                    u.screen_name.clone().unwrap_or_default(),
                    u.idstr.clone().unwrap_or_default()
                );
            }
        }

        "detail" => {
            let mid = args.get(2).cloned().unwrap_or_default();
            if mid.is_empty() {
                return Err(WeiboError::protocol("用法: detail <mid>"));
            }
            let s = client.status_detail(mid)?;
            println!(
                "作者 : {} ({})",
                s.user.as_ref().and_then(|u| u.screen_name.clone()).unwrap_or_default(),
                s.user.as_ref().and_then(|u| u.idstr.clone()).unwrap_or_default()
            );
            println!("时间 : {}", s.created_at.clone().unwrap_or_default());
            println!("来源 : {}", s.source.clone().unwrap_or_default());
            println!("mid  : {}", s.idstr.clone().unwrap_or_default());
            println!("{}", "─".repeat(60));
            println!("{}", s.plain_text());
            println!("{}", "─".repeat(60));
            println!(
                "转发 {}  评论 {}  赞 {}",
                s.reposts_count.unwrap_or(0),
                s.comments_count.unwrap_or(0),
                s.attitudes_count.unwrap_or(0)
            );
        }

        // ------------------------------ 视频（只读） ------------------------------
        "video" => {
            // 参数：video <mid> [--json <文件>]。带 --json 时 mid 可省（用响应里的 idstr）。
            let json_file = arg_value(args, "--json");
            let mid_arg = args
                .get(2)
                .filter(|a| !a.starts_with("--"))
                .cloned()
                .unwrap_or_default();

            let s = match &json_file {
                Some(path) => client.parse_status_raw(read_json_file(path)?)?,
                None => {
                    if mid_arg.is_empty() {
                        return Err(WeiboError::protocol("用法: video <mid> [--json <文件>]"));
                    }
                    client.status_detail(mid_arg.clone())?
                }
            };

            let mid = s.idstr.clone().unwrap_or(mid_arg);
            println!(
                "作者 : {} ({})",
                s.user.as_ref().and_then(|u| u.screen_name.clone()).unwrap_or_default(),
                s.user.as_ref().and_then(|u| u.idstr.clone()).unwrap_or_default()
            );
            println!("mid  : {mid}");
            println!("链接 : https://weibo.com/{mid}");
            if let Some(rt) = s.retweeted_status.as_ref() {
                println!(
                    "转发自: {} ({})",
                    rt.user.as_ref().and_then(|u| u.screen_name.clone()).unwrap_or_default(),
                    rt.idstr.clone().unwrap_or_default()
                );
            }

            println!("{}", "─".repeat(60));
            println!("page_info 原始 JSON：");
            match s.page_info.as_deref() {
                Some(raw) => match serde_json::from_str::<serde_json::Value>(raw) {
                    Ok(v) => println!(
                        "{}",
                        serde_json::to_string_pretty(&v).unwrap_or_else(|_| raw.to_string())
                    ),
                    Err(_) => println!("{raw}"),
                },
                None => println!("(本条没有 page_info)"),
            }
            if let Some(raw) = s.retweeted_status.as_ref().and_then(|rt| rt.page_info.as_deref()) {
                println!("retweeted_status.page_info 原始 JSON：");
                match serde_json::from_str::<serde_json::Value>(raw) {
                    Ok(v) => println!(
                        "{}",
                        serde_json::to_string_pretty(&v).unwrap_or_else(|_| raw.to_string())
                    ),
                    Err(_) => println!("{raw}"),
                }
            }
            println!("{}", "─".repeat(60));

            // 类型化解析结果（本条；转发视频另打印）
            match s.page_info_parsed() {
                Some(pi) => println!(
                    "card type={:?}  object_type={:?}  判定={}",
                    pi.page_type,
                    pi.object_type,
                    if pi.is_video() { "视频" } else { "非视频/其它卡片" }
                ),
                None => println!("card : (page_info 无法解析或缺字段)"),
            }
            if let Some(rt) = s.retweeted_status.as_ref() {
                if let Some(pi) = rt.page_info_parsed() {
                    println!(
                        "转发 card type={:?}  object_type={:?}  判定={}",
                        pi.page_type,
                        pi.object_type,
                        if pi.is_video() { "视频" } else { "非视频/其它卡片" }
                    );
                }
            }

            println!(
                "时长 : {}",
                s.video_duration()
                    .map(|d| format!("{d}s"))
                    .unwrap_or_else(|| "(无)".into())
            );
            println!(
                "封面 : {}",
                s.video_cover_url().unwrap_or_else(|| "(无)".into())
            );
            match s.video_url_with_source() {
                Some((u, src)) => {
                    println!("视频 : {u}");
                    println!("来源 : {src}");
                }
                None => println!("视频 : (未提取到视频 URL)"),
            }
        }

        "videos" => {
            // 参数：videos [n] [--json <文件>]
            let json_file = arg_value(args, "--json");
            let n: u32 = args
                .get(2)
                .filter(|a| !a.starts_with("--"))
                .and_then(|s| s.parse().ok())
                .unwrap_or(20);

            let list: Vec<Status> = match &json_file {
                // 离线重放：与联网路径共用 parse_timeline_raw
                Some(path) => client.parse_timeline_raw(read_json_file(path)?),
                None => {
                    println!("扫描前 {n} 条…");
                    // 首页时间线优先；该端点对访客/异常登录态可能不可用，退关注流。
                    match client.home_timeline(n, "0".into()) {
                        Ok(l) => l,
                        Err(e) => {
                            eprintln!("⚠ 首页时间线不可用（{e:?}），改试关注时间线…");
                            client.following_timeline(n)?
                        }
                    }
                }
            };

            println!("共 {} 条，以下是带视频的：\n", list.len());
            let mut found = 0usize;
            for s in &list {
                let Some((u, src)) = s.video_url_with_source() else { continue };
                found += 1;
                let name = s
                    .user
                    .as_ref()
                    .and_then(|u| u.screen_name.clone())
                    .unwrap_or_else(|| "?".into());
                println!(
                    "{found}. mid={}  作者={name}  来源={src}",
                    s.idstr.clone().unwrap_or_default()
                );
                println!("   URL : {u}");
                if let Some(c) = s.video_cover_url() {
                    println!("   封面: {c}");
                }
                if let Some(d) = s.video_duration() {
                    println!("   时长: {d}s");
                }
                let t: String = s.plain_text().replace('\n', " ").chars().take(60).collect();
                if !t.trim().is_empty() {
                    println!("   文字: {t}");
                }
            }
            if found == 0 {
                println!("（{} 条里没有带视频的微博）", list.len());
            }
        }

        "comments" => {
            let mid = args.get(2).cloned().unwrap_or_default();
            if mid.is_empty() {
                return Err(WeiboError::protocol("用法: comments <mid> [n]"));
            }
            let n: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(20);
            // flow=1（按时间）才能翻页；flow=0 按热度翻页实测无效
            let list: Vec<Comment> = client.comments(mid, n, 0, 1)?;
            println!("评论（{} 条）\n", list.len());
            for c in list {
                let who = c
                    .user
                    .as_ref()
                    .and_then(|u| u.screen_name.clone())
                    .unwrap_or_else(|| "?".into());
                let mark = if c.is_author == Some(true) { " [作者]" } else { "" };
                let text: String = c.plain_text().replace('\n', " ").chars().take(100).collect();
                println!("· {who}{mark}: {text}  （赞 {}）", c.like_counts.unwrap_or(0));
            }
        }

        // 我的评论（发出的评论）。不带游标 = 第一页；`--cursor <n>` 翻页。
        "mycomments" => {
            let cursor: Option<i64> = arg_value(args, "--cursor").and_then(|s| s.parse().ok());
            let p = client.my_comments(cursor)?;
            println!(
                "我的评论（本页 {} 条，共 {} 条）\n",
                p.comments.len(),
                p.total_number.unwrap_or(-1)
            );
            for c in &p.comments {
                let text: String = c.plain_text().replace('\n', " ").chars().take(90).collect();
                let root = c
                    .status
                    .as_ref()
                    .map(|s| {
                        let who = s
                            .user
                            .as_ref()
                            .and_then(|u| u.screen_name.clone())
                            .unwrap_or_else(|| "?".into());
                        let t: String = s.plain_text().replace('\n', " ").chars().take(45).collect();
                        format!("{who}: {t}")
                    })
                    .unwrap_or_else(|| "(无原微博)".into());
                println!("· {text}\n    原微博 ← {root}");
            }
            if let Some(n) = p.next_cursor {
                println!("\n下一页游标: {n}（--cursor {n}）");
            }
        }

        // 回复我的评论（别人回复我发出的评论）。`--cursor <n>` 翻页。
        "replies" => {
            let cursor: Option<i64> = arg_value(args, "--cursor").and_then(|s| s.parse().ok());
            let p = client.received_comments(cursor)?;
            println!(
                "回复我的评论（本页 {} 条，共 {} 条）\n",
                p.comments.len(),
                p.total_number.unwrap_or(-1)
            );
            for c in &p.comments {
                let who = c
                    .user
                    .as_ref()
                    .and_then(|u| u.screen_name.clone())
                    .unwrap_or_else(|| "?".into());
                let text: String = c.plain_text().replace('\n', " ").chars().take(70).collect();
                let mine: String = c
                    .reply_comment
                    .as_ref()
                    .map(|m| m.plain_text().replace('\n', " ").chars().take(40).collect())
                    .unwrap_or_default();
                let root: String = c
                    .status
                    .as_ref()
                    .map(|s| {
                        let u = s
                            .user
                            .as_ref()
                            .and_then(|u| u.screen_name.clone())
                            .unwrap_or_else(|| "?".into());
                        let t: String = s.plain_text().replace('\n', " ").chars().take(30).collect();
                        format!("{u}: {t}")
                    })
                    .unwrap_or_else(|| "(无)".into());
                println!("· {who} 回复: {text}");
                println!("    我原来: {mine}");
                println!("    原微博: {root}");
            }
            if let Some(n) = p.next_cursor {
                println!("\n下一页游标: {n}（--cursor {n}）");
            }
        }

        "reposts" => {
            let mid = args.get(2).cloned().unwrap_or_default();
            if mid.is_empty() {
                return Err(WeiboError::protocol("用法: reposts <mid>"));
            }
            let list = client.reposts(mid, 1)?;
            println!("转发（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "search" => {
            let q = free_text(&args[2.min(args.len())..]);
            if q.trim().is_empty() {
                return Err(WeiboError::protocol("用法: search <关键词>"));
            }
            let list = client.search(q.clone(), 20, 1)?;
            println!("搜索「{q}」（{} 条）\n", list.len());
            print_statuses(&list);
        }

        "longtext" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: longtext <id>"));
            }
            match client.long_text(id)? {
                Some(t) if !t.trim().is_empty() => {
                    println!("长文全文（{} 字）：", t.chars().count());
                    println!("{t}");
                }
                _ => println!("这条不是长文，或没有全文"),
            }
        }

        // ------------------------------ 写操作 ------------------------------
        "like" | "unlike" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: like|unlike <id> [--yes]"));
            }
            let what = if cmd == "like" { "点赞" } else { "取消赞" };
            if !confirm(args, what) {
                return Ok(());
            }
            if cmd == "like" {
                client.set_like(id.clone())?;
            } else {
                client.cancel_like(id.clone())?;
            }
            println!("✓ 已{what} {id}");
        }

        "repost" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: repost <id> [文字] [--yes]"));
            }
            let text = free_text(&args[3.min(args.len())..]);
            if !confirm(args, "转发") {
                return Ok(());
            }
            client.repost(id.clone(), text, false, String::new())?;
            println!("✓ 已转发 {id}");
        }

        "comment" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: comment <id> <文字> [--yes]"));
            }
            let text = free_text(&args[3.min(args.len())..]);
            if text.trim().is_empty() {
                return Err(WeiboError::protocol("评论内容不能为空"));
            }
            if !confirm(args, "评论") {
                return Ok(());
            }
            client.comment(id.clone(), text, None, false, String::new())?;
            println!("✓ 已评论 {id}");
        }

        "fav" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: fav <id> [--off] [--yes]"));
            }
            let off = args.iter().any(|a| a == "--off");
            let what = if off { "取消收藏" } else { "收藏" };
            if !confirm(args, what) {
                return Ok(());
            }
            client.favorite(id.clone(), !off)?;
            println!("✓ 已{what} {id}");
        }

        "delete" => {
            let id = args.get(2).cloned().unwrap_or_default();
            if id.is_empty() {
                return Err(WeiboError::protocol("用法: delete <id> --yes"));
            }
            if !args.iter().any(|a| a == "--yes") {
                println!("⚠ 删除不可撤销，确认请加 --yes");
                return Ok(());
            }
            client.destroy_status(id.clone())?;
            println!("✓ 已删除 {id}");
        }

        "mylatest" => match client.my_blog(None, 1)?.first() {
            None => println!("（没有微博）"),
            Some(s) => {
                println!("idstr : {}", s.idstr.clone().unwrap_or_default());
                println!("时间  : {}", s.created_at.clone().unwrap_or_default());
                let t: String = s.plain_text().chars().take(60).collect();
                println!("内容  : {t}");
            }
        },

        "post" => {
            let text = free_text(&args[1..]);
            if text.trim().is_empty() {
                return Err(WeiboError::protocol("内容不能为空"));
            }
            let visible: u32 = if args.iter().any(|a| a == "--private") {
                6
            } else if args.iter().any(|a| a == "--followers") {
                1
            } else {
                0
            };
            if !confirm(args, "发微博") {
                return Ok(());
            }
            let id = client.post_status(text, visible)?;
            println!("✓ 已发布，id={id}");
            println!("  （要删就运行： weibo-cli delete {id} --yes）");
        }

        other => {
            return Err(WeiboError::protocol(format!("未知命令: {other}")));
        }
    }
    Ok(())
}

// ------------------------------------------------------------------ main

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    if cmd == "help" {
        println!(
            "weibo-cli —— 微博第三方客户端（Rust）\n\n\
             \x20 login / whoami / logout\n\
             \x20 hot / band / timeline [n] / following [n]\n\
             \x20 meblog / user <uid> / followed\n\
             \x20 detail <mid> / comments <mid> [n] / reposts <mid>\n\
             \x20 search <关键词> / longtext <id> / mylatest\n\
             \x20 video <mid> / videos [n]         （只读；均支持 --json <文件> 离线重放）\n\
             \x20 post <内容> [--private|--followers] [--yes]\n\
             \x20 like|unlike <id> / repost <id> [文字] / comment <id> <文字> / fav <id> [--off] / delete <id>\n\n\
             写操作需 --yes 确认"
        );
        return;
    }

    let engine: Arc<dyn HttpEngine> = match ReqwestEngine::new() {
        Ok(e) => e,
        Err(e) => die(format!("创建 HTTP 引擎失败: {e:?}")),
    };
    let client = WeiboClient::new(engine);
    let cookie = cookie_path();

    if cmd == "logout" {
        let _ = std::fs::remove_file(&cookie);
        println!("已删除本地 cookie: {}", cookie.display());
        return;
    }

    if cmd == "login" {
        do_login(&client, &cookie);
        return;
    }

    let logged_in = client.restore(cookie.to_string_lossy().to_string());

    // 公开接口不需要登录态：
    //  - hot / band 本来就是公开榜；
    //  - video 走 `statuses/show`，单条公开微博对访客也返回数据（实测）；
    //  - videos --json 只是解析本地已保存的响应，不需要联网登录。
    // 其余命令仍需登录；videos 联网扫流也仍要求登录。
    let public = matches!(cmd, "hot" | "band")
        || cmd == "video"
        || (cmd == "videos" && args.iter().any(|a| a == "--json"));
    if !logged_in && !public {
        die("未登录，请先执行: weibo-cli login");
    }

    if let Err(e) = run_command(&client, cmd, &args) {
        die(format!("{e:?}"));
    }
}
