# weibo-client-kt

微博第三方客户端 —— **Rust 核心 + Kotlin/Compose UI**，基于实测验证的 **Web 接口**实现。

- ❌ 不碰私有 API（`api.weibo.cn`）
- ❌ 不碰签名（`s` 参数）
- ❌ 不需要 root / Xposed / frida
- ✅ 扫码登录 → 拿 `SUB` cookie → 调 `weibo.com/ajax/*`

> 背景：官方私有 API 被 `-105 客户端身份校验`（绑定 APK 签名）封死；第三方客户端 See微博 的登录契约也因微博废弃旧 OAuth 页面而失效。Web 接口是目前唯一干净且可持续的路。

## 架构

```
┌──────────────────────────────────────────────────────┐
│  app/   Android 客户端（Jetpack Compose UI）          │
└──────────────────┬───────────────────────────────────┘
                   │ UniFFI 自动生成的 Kotlin 绑定
┌──────────────────▼───────────────────────────────────┐
│  rust/  微博核心（Rust，编译为 libweibo_core.so）      │
│    http.rs            cookie 罐 + 自跟随重定向 + CSRF  │
│    auth.rs            扫码登录（SSO v2）               │
│    models.rs          数据模型（serde）                │
│    client.rs          API 门面（接口全集中于此）        │
│    reqwest_engine.rs  真实 HTTP 引擎（CLI 用）         │
└──────────────────────────────────────────────────────┘
```

**HTTP 层通过 `HttpEngine` 接口注入**，跨语言：
- Rust 侧是 trait（`#[uniffi::export(with_foreign)]`）
- Android 用 `OkHttpEngine`（OkHttp）
- CLI 用 `ReqwestEngine`（reqwest）

核心**不含任何平台特有代码**，同一份 Rust 同时供 Android 与 CLI 使用。
接口层集中在 `client.rs` —— 微博前端一改只需动这一个文件。

> 历史：核心原先用 Kotlin 实现（`core/` 模块），已整体迁移到 Rust 并逐项验证。
> 旧代码在 git 历史中可随时取回：`git show <旧提交>:core/src/main/kotlin/com/cx/weibo/WeiboCore.kt`

## 快速开始

### CLI

```bash
cd rust
cargo build --release
./target/release/weibo-cli login      # 扫码登录，自动保存会话
./target/release/weibo-cli whoami     # 看当前账号
./target/release/weibo-cli timeline   # 首页时间线
./target/release/weibo-cli hot        # 热搜榜
```

会话保存在 `~/.weibo-client/cookies.tsv`（有效期约 30 天，过期重新 `login`）。

### Android

```bash
# 需要：JDK 17+、Android SDK、Android NDK、rustup
export ANDROID_NDK_HOME=$HOME/Android/Sdk/ndk/<版本>
./gradlew :app:assembleDebug
```

Gradle 会自动完成：`cargo build`（host，供生成绑定）→ UniFFI 生成 Kotlin 绑定
→ `cargo ndk` 交叉编译 3 个 ABI → 打进 APK。
加 `-PskipRust` 可跳过 Rust 构建（复用已有产物，改 UI 时更快）。

## 命令

| 命令 | 说明 |
|---|---|
| `login` | 扫码登录。二维码存到 `~/.weibo-client/qr.png`，用手机微博 App 扫 |
| `whoami` | 当前账号资料 |
| `hot` | 热搜榜（简） |
| `band` | 热搜榜（含标签/热度值） |
| `timeline [n]` | 首页时间线（默认 20 条） |
| `following [n]` | 关注时间线（纯关注、时间序、无广告） |
| `meblog` | 我的微博 |
| `user <uid>` | 指定用户的微博 |
| `followed` | 关注列表 |
| `detail <mid>` | 单条微博详情 |
| `comments <mid> [n]` | 评论列表 |
| `reposts <mid>` | 转发列表 |
| `search <关键词>` | 搜索微博 |
| `longtext <id>` | 长文全文 |
| `mylatest` | 我发的最新一条 |
| `logout` | 清除本地会话 |

**写操作**（真实账号生效，需显式 `--yes`）：

| 命令 | 说明 |
|---|---|
| `post <内容> [--private\|--followers]` | 发微博（公开 / 仅自己 / 仅关注） |
| `like <id>` / `unlike <id>` | 点赞 / 取消赞 |
| `repost <id> [文字]` | 转发 |
| `comment <id> <文字>` | 评论 |
| `fav <id> [--off]` | 收藏 / 取消收藏 |
| `delete <id>` | 删除自己发的微博 |

## 关键实现细节（踩过的坑）

**1. cookie 罐必须按 `(域名, 名字)` 做键**
微博 SSO 回调链会在 `.weibo.com` / `.sina.com.cn` / `.sina.cn` / `.weibo.cn`
**依次下发同名 `SUB`**。只按名字存会互相覆盖，导致 `weibo.com` 拿不到登录态。

**2. 必须自己跟随重定向**
自动跟随会**丢弃中间跳转的 `Set-Cookie`**，而微博登录恰好依赖跨跳转下发。
所以：`reqwest` 要显式 `.redirect(Policy::none())`，OkHttp 要 `followRedirects(false)`。

**3. `weibo.com/ajax/*` 强制校验 `Referer`**
缺失返回 `403 {"error":"Forbidden"}`。已默认补 `https://weibo.com/`（登录后为 `/u/<uid>`）。

**4. 写接口要 CSRF 双提交**
cookie `XSRF-TOKEN` + 请求头 `X-XSRF-TOKEN`，少了会返回 `invalid csrf token`。
`ensure_xsrf()` 会在写操作前补一次主页访问以拿到令牌。

**5. `isAd` 字段是多态的**
实测有时是 `bool`、有时是数字、有时是字符串 —— 用具体类型承接会解析失败。
Rust 侧存 JSON 文本后按类型判定（见 `models.rs::is_ad_flag`）。

## 已验证接口

| 功能 | 接口 |
|---|---|
| 首页时间线 | `/ajax/feed/unreadfriendstimeline?since_id=0&refresh=1&count=20` |
| 关注时间线 | `/ajax/feed/friendstimeline?page=1&count=25` |
| 我的资料 | `/ajax/profile/info?uid=` |
| 微博列表（本人/他人） | `/ajax/statuses/mymblog?uid=&page=1&feature=0` |
| 单条微博详情 | `/ajax/statuses/show?id=<mid>`（**无 ok 信封，直接返回对象**） |
| 长文全文 | `/ajax/statuses/longtext?id=<idstr>` |
| 评论 | `/ajax/statuses/buildComments?is_reload=1&id=&is_show_bulletin=2&is_mix=0&count=&max_id=&flow=` |
| 转发 | `/ajax/statuses/repostTimeline?id=&page=1` |
| 搜索微博 | `/ajax/statuses/search?q=&count=&page=` |
| 关注列表 | `/ajax/profile/followContent?uid=` |
| 热搜榜（简/详） | `/ajax/side/hotSearch` · `/ajax/statuses/hot_band?band_id=1&count=50` |
| 点赞 / 转发 / 评论 / 收藏 / 删除 / 发博 | `/ajax/statuses/{setLike,cancelLike,repost,destroy,update}` 等 |

### 已确认不可用

| 接口 | 结果 |
|---|---|
| `/ajax/statuses/likeTimeline` | 你访问的地址不存在 |
| `/ajax/search/all` · `/ajax/search/statuses` | 你访问的地址不存在 |
| `/ajax/profile/getFriendList` | 你访问的地址不存在 |

## 实现细节备注

- `statuses/show` 的返回**没有 `ok` 信封**，直接是微博对象 —— 不要套 `checkOk`。
- 首页时间线翻页用 `since_id`（零重叠）；**关注时间线的 `since_id` 翻页实测无效**
  （第二页与第一页 100% 重叠），必须用 `page=N`。
- 评论：`count` 参数被忽略（固定 20 条）；**按热度（flow=0）翻不了页**，要完整列表请用 `flow=1`（按时间）。
- 搜索结果没有 `since_id`/`max_id`，翻页用 `page` 参数。
- `mymblog` 对**空账号**返回 `ok:1` + 空 `list`（不是错误），不要误判为失败。
- 长文会被服务端截断（`isLongText=true`），全文需单独调 `longtext`。

## 文档

- **[API.md](API.md)** —— 完整的第三方接入文档（认证流程 / 全部接口 / 错误码 / 坑位），供他人直接用
- `docs/WEIBO-WEB-API-INVENTORY.md` —— 协议逆向存档
- `docs/WEIBO-H5-ANALYSIS.md` —— 登录协议分析

## 风险

- **接口无契约**：微博前端更新可能导致接口失效（已做接口层隔离便于修补）
- **风控**：Web 端对自动化敏感，写操作尤其要节流
- **Cookie 30 天过期**：需重新扫码
- **合规**：仅限自用 / 学习，公开发布违反平台协议

## 环境依赖

| 用途 | 依赖 |
|---|---|
| Rust 核心 + CLI | rustup（本仓库验证于 rustc 1.99.0） |
| Android 交叉编译 | Android NDK + `cargo-ndk` |
| Android 构建 | JDK 17+、Android SDK |
| Gradle | wrapper 8.12.1（`./gradlew`，自动解析依赖） |

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
```
