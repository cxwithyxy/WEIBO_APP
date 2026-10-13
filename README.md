# weibo-client-kt

微博第三方客户端（**纯 Kotlin 库 + CLI**），基于 Agent 逆向并实测验证的 **Web 接口**实现。

- ❌ 不碰私有 API（`api.weibo.cn`）
- ❌ 不碰签名（`s` 参数）
- ❌ 不需要 root / Xposed / frida
- ✅ 扫码登录 → 拿 `SUB` cookie → 调 `weibo.com/ajax/*`

> 背景：官方私有 API 被 `-105 客户端身份校验`（绑定 APK 签名）封死；第三方客户端 See微博 的登录契约也因微博废弃旧 OAuth 页面而失效。Web 接口是目前唯一干净且可持续的路。

## 快速开始

```bash
./build.sh          # 编译（Gradle wrapper 自动解析依赖）
./run.sh login      # 扫码登录，自动保存会话
./run.sh whoami     # 看当前账号
./run.sh timeline   # 首页时间线
./run.sh hot        # 热搜榜
```

会话保存在 `~/.weibo-client/cookies.tsv`（有效期约 30 天，过期重新 `login`）。

## 命令

| 命令 | 说明 |
|---|---|
| `login` | 扫码登录。二维码存到 `~/.weibo-client/qr.png`，用手机微博 App 扫 |
| `whoami` | 当前账号资料 |
| `hot` | 热搜榜（简） |
| `band` | 热搜榜（含标签/热度值） |
| `timeline [n]` | 首页时间线（默认 20 条） |
| `meblog` | 我的微博 |
| `user <uid>` | 指定用户的微博 |
| `following` | 关注列表 |
| `detail <mid>` | 单条微博详情 |
| `comments <mid> [n]` | 评论列表 |
| `reposts <mid>` | 转发列表 |
| `search <关键词>` | 搜索微博 |
| `logout` | 清除本地会话 |

## 作为库使用

```kotlin
val client = WeiboClient(JvmHttpEngine())
val cookieFile = Path.of(System.getProperty("user.home"), ".weibo-client", "cookies.tsv")

if (!client.restore(cookieFile)) {
    // 取码 → 展示 → 等待扫描
    client.auth.loginBlocking(
        onQr = { qr -> println("二维码: ${qr.imageUrl}") },
        onState = { st -> println("状态: ${st.state}") },
    )
    client.save(cookieFile)
}

client.homeTimeline(count = 20).forEach { println(it.user?.screenName + ": " + it.plainText) }
client.hotSearch().take(10).forEach { println(it.word) }
```

## 结构

```
core/                           协议核心（平台无关）
└── com/cx/weibo/
    ├── http/HttpEngine.kt      HTTP 引擎接口（由平台注入）
    ├── WeiboCore.kt            模型 + WeiboHttp（自管 cookie / 自跟随重定向）
    ├── WeiboAuth.kt            扫码登录（SSO v2）
    └── WeiboClient.kt          API 门面（接口全集中于此，便于修补）

cli/                            JVM 命令行前端
└── com/cx/weibo/
    ├── http/JvmHttpEngine.kt   java.net.http 实现
    └── cli/Main.kt             CLI 命令
```

**HTTP 层通过 `HttpEngine` 接口注入**：CLI 用 `JvmHttpEngine`（`java.net.http`），
Android 端将用 `OkHttpEngine`。`core` 不含任何平台特有 API，可直接被 Android 复用。

接口层**集中隔离**在 `WeiboClient.kt` —— 微博前端一改只需动这一个文件。

## 两个关键实现细节（踩过的坑）

**1. `weibo.com/ajax/*` 强制校验 `Referer`**
缺失会返回 `403 {"error":"Forbidden"}`。库已默认补 `https://weibo.com/`（登录后为 `/u/<uid>`）。

**2. 不能用 JDK 的 `CookieManager`**
- 外部注入的 cookie 它**不往外发**（实测导致被重定向到登录页，而 curl 正常）
- 自动跟随重定向时，**中间跳转的 `Set-Cookie` 会被丢弃** —— 而微博登录恰好依赖跨跳转下发的 cookie

因此 `WeiboHttp` **自己管 cookie、自己跟随重定向**，每跳都吸收 `Set-Cookie`。

## 已验证接口

| 功能 | 接口 |
|---|---|
| 首页时间线 | `/ajax/feed/unreadfriendstimeline?since_id=0&refresh=1&count=20` |
| 我的资料 | `/ajax/profile/info?uid=` |
| 个人详情 | `/ajax/profile/detail?uid=` |
| 微博列表（本人/他人） | `/ajax/statuses/mymblog?uid=&page=1&feature=0` |
| 单条微博详情 | `/ajax/statuses/show?id=<mid>`（**无 ok 信封，直接返回对象**） |
| 评论 | `/ajax/statuses/buildComments?is_reload=1&id=&is_show_bulletin=2&is_mix=0&count=&max_id=&flow=` |
| 转发 | `/ajax/statuses/repostTimeline?id=&page=1` |
| 搜索微博 | `/ajax/statuses/search?q=&count=&page=` |
| 搜索联想词 | `/ajax/side/search?q=` |
| 关注列表 | `/ajax/profile/followContent?uid=` |
| 热搜榜（简） | `/ajax/side/hotSearch`（公开） |
| 热搜榜（详） | `/ajax/statuses/hot_band?band_id=1&count=50` |

### 已确认不可用

| 接口 | 结果 |
|---|---|
| `/ajax/statuses/likeTimeline` | 你访问的地址不存在 |
| `/ajax/search/all` · `/ajax/search/statuses` | 你访问的地址不存在 |
| `/ajax/profile/getFriendList` | 你访问的地址不存在 |

登录协议细节见 `docs/WEIBO-H5-ANALYSIS.md`，接口清单见 `docs/WEIBO-WEB-API-INVENTORY.md`。

## 尚未实现

- 话题 / 超话详情
- 用户搜索（仅微博搜索可用）
- 写操作（发博 / 转发 / 点赞 / 评论）—— 风控敏感，需节流
- UI（Android / Compose）

## 实现细节备注

- `statuses/show` 的返回**没有 `ok` 信封**，直接是微博对象 —— 不要套 `checkOk`。
- 评论：`count` 参数被忽略（固定 20 条）；**按热度（flow=0）翻不了页**，要完整列表请用 `flow=1`（按时间）。
- 搜索结果没有 `since_id`/`max_id`，翻页用 `page` 参数。
- `mymblog` 对**空账号**返回 `ok:1` + 空 `list`（不是错误），不要误判为失败。

## 文档

- **[API.md](API.md)** —— 完整的第三方接入文档（认证流程 / 全部接口 / 错误码 / 坑位），供他人直接用
- `docs/WEIBO-WEB-API-INVENTORY.md` —— 协议逆向存档

## 风险

- **接口无契约**：微博前端更新可能导致接口失效（已做接口层隔离便于修补）
- **风控**：Web 端对自动化敏感，写操作尤其要节流
- **Cookie 30 天过期**：需重新扫码
- **合规**：仅限自用 / 学习，公开发布违反平台协议

## 环境依赖

- JDK 21（`java.net.http.HttpClient`）
- Gradle wrapper 8.12.1（`./gradlew`，自动解析依赖）
- Kotlin 2.0.21 / Gson 2.11.0（由 Gradle 从 Maven Central 解析）
