# 微博 Web API 文档

> 面向第三方客户端的接口说明　v1.0　2026-10-13
> 所有接口均经**真实会话实测**，非推测。

## ⚠️ 免责声明

本文档记录的是**微博网页版内部接口**（非官方开放平台），用于**个人学习 / 自有账号互操作研究**。

- 接口**无公开契约**，微博随时可能更改
- 严禁用于爬虫抓取、批量操作、账号买卖等违规用途
- 公开发布基于本接口的客户端可能违反《微博服务使用协议》
- 使用者自行承担一切后果

---

## 目录

1. [快速开始](#1-快速开始)
2. [认证：扫码登录](#2-认证扫码登录)
3. [HTTP 层硬性要求](#3-http-层硬性要求)
4. [接口参考](#4-接口参考)
5. [错误码](#5-错误码)
6. [已知坑位](#6-已知坑位)
7. [风控与工程建议](#7-风控与工程建议)
8. [Kotlin 库用法](#8-kotlin-库用法)

---

## 1. 快速开始

```bash
# ① 先访问登录页（建立会话，下发 X-CSRF-TOKEN）
curl -s -c jar.txt 'https://passport.weibo.com/sso/signin?entry=wapsso&source=wapssowb' > /dev/null

# ② 取二维码
curl -s -b jar.txt -c jar.txt \
  'https://passport.weibo.com/sso/v2/qrcode/image?entry=wapsso&size=300'
# → {"retcode":20000000,"data":{"qrid":"<QRID>","image":"https://v2.qr.weibo.cn/inf/gen?..."}}

# ③ 用手机微博 App 扫上面 image 的二维码，然后轮询：
curl -s -b jar.txt -c jar.txt \
  'https://passport.weibo.com/sso/v2/qrcode/check?entry=wapsso&source=wapssowb&url=https%3A%2F%2Fm.weibo.cn%2F&qrid=<QRID>&disp=&rid=norid&ver=20250520'
# 确认后返回的 data.url 里跟随跳转 → jar.txt 里就有 SUB cookie

# ④ 带 cookie 调接口（注意 Referer 必填！）
curl -s -b jar.txt \
  -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36' \
  -H 'Referer: https://weibo.com/' \
  -H 'X-Requested-With: XMLHttpRequest' \
  'https://weibo.com/ajax/feed/unreadfriendstimeline?since_id=0&refresh=1&count=20'
```

> 注：`jar.txt` 必须用 `-c` 一路写回，否则**跨跳转下发的 cookie 会丢**。

---

## 2. 认证：扫码登录

**不需要** root / 签名 / 密码 / RSA。纯 HTTP。

### 流程

```
① GET  https://passport.weibo.com/sso/signin?entry=wapsso&source=wapssowb
        → 建立会话，下发 X-CSRF-TOKEN

② GET  https://passport.weibo.com/sso/v2/qrcode/image?entry=wapsso&size=300
        → {"retcode":20000000,"data":{"qrid":"...","image":"<二维码图URL>"}}

③ 用手机微博 App 扫描 image，并在手机上「确认登录」

④ GET  https://passport.weibo.com/sso/v2/qrcode/check
        ?entry=wapsso&source=wapssowb
        &url=https%3A%2F%2Fm.weibo.cn%2F      ← 需 URL 编码
        &qrid=<QRID>
        &disp=&rid=norid&ver=20250520
        → 状态码见下表；确认后 data.url 为跳转地址

⑤ 跟随 data.url 的跳转链（最多 10 跳，每跳都收 Set-Cookie）
        → 得到 cookie（域 .weibo.com，有效期约 30 天）
```

### 轮询状态码

| retcode | 含义 | 处理 |
|---|---|---|
| `20000000` | ✅ 已确认 | 跟随 `data.url` |
| `50114001` | 未使用（等待扫描） | 继续轮询（建议 2s 间隔） |
| `50114002` | 已扫描，待手机确认 | 继续轮询 |
| `50114003` / `50114004` / `50114015` | 二维码已过期 | 重新取码 |
| 其他 | 错误 | 记录 `msg` |

### 得到的 cookie

| 名称 | 说明 |
|---|---|
| `SUB` | **主登录态**（HttpOnly）—— 认证的核心 |
| `SUBP` | 配套会话 |
| `ALF` / `ALC` | 有效期控制 |
| `SCF` | 辅助 |

> **判定登录态 = `SUB` 是否存在且非空。**

### 取自己的 uid

```bash
curl -s -b jar.txt -H 'User-Agent: <桌面UA>' 'https://weibo.com/' | grep -o '"uid":[0-9]*'
# → "uid":1234567890
```

---

## 3. HTTP 层硬性要求

### 3.1 `Referer` 是硬性校验 ⚠️

`weibo.com/ajax/*` **强制校验 Referer**，缺失直接：

```json
HTTP 403  {"error":"Forbidden"}
```

| 场景 | Referer |
|---|---|
| 未登录 / 通用 | `https://weibo.com/` |
| 已登录 | `https://weibo.com/u/<uid>` |

### 3.2 必须的请求头

```http
User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36
Accept-Language: zh-CN,zh;q=0.9
Referer: https://weibo.com/
X-Requested-With: XMLHttpRequest
Accept: application/json, text/plain, */*
```

移动版 UA 也能用，但**桌面 UA 与本文档接口路径一致**，建议照抄。

### 3.3 ⚠️ 不要用 JDK 的 `CookieManager`

实测两个致命问题（用 curl 对照时 curl 正常、Java 失败）：

| 问题 | 后果 |
|---|---|
| 外部注入的 cookie **不外发** | 被重定向到登录页 |
| 自动跟随重定向时，**中间跳转的 `Set-Cookie` 被丢弃** | 登录拿不到 `SUB` |

**必须自管 cookie + 自跟随重定向**，每跳都吸收 `Set-Cookie`。
（其他语言的 HTTP 库若有同类行为，同样注意。）

### 3.4 POST 必须用表单编码

登录相关 POST 的 `Content-Type` **必须是 `application/x-www-form-urlencoded`**。
用 JSON 会被 APISIX 网关拦截，返回 `6102`。

---

## 4. 接口参考

> 基础地址 `https://weibo.com`。所有接口均需登录态（`hotSearch` 除外）。

### 4.1 热搜榜（公开，无需登录）

```
GET /ajax/side/hotSearch
```

响应 `data.realtime[]`：`{ word, num, realpos, label }`

```json
{"ok":1,"data":{"realtime":[{"word":"79岁老干妈陶华碧用AI一年赚54亿","num":1588145,"realpos":1}]}}
```

### 4.2 热搜榜（详情版）

```
GET /ajax/statuses/hot_band?band_id=1&count=50
```

响应 `data.band_list[]`：`{ word, note, num, rank, realpos, label_name, icon_desc, word_scheme }`

| 参数 | 说明 |
|---|---|
| `band_id` | 榜单 ID（`1` = 主榜；实测 1/2 内容基本相同） |
| `count` | 条数 |

```json
{"ok":1,"http_code":200,"data":{"band_list":[
  {"word":"79岁老干妈陶华碧用AI一年赚54亿","note":"","num":1532983,"realpos":1,"label_name":"热"}
]}}
```

### 4.3 我的资料

```
GET /ajax/profile/info?uid=<uid>
```

响应 `data.user`：`{ id, idstr, screen_name, profile_image_url, followers_count, friends_count, statuses_count, description, verified, location }`

```json
{"ok":1,"data":{"user":{"idstr":"1234567890","screen_name":"示例用户","followers_count":1234}}}
```

### 4.4 个人详情

```
GET /ajax/profile/detail?uid=<uid>
```

响应 `data`：`{ career, company, education, birthday, sunshine_credit, ... }`

### 4.5 微博列表（本人 / 他人通用）

```
GET /ajax/statuses/mymblog?uid=<uid>&page=1&feature=0
```

响应：`data.list[]`（微博对象）、`data.since_id`、`data.total`

| 参数 | 说明 |
|---|---|
| `uid` | 目标用户 |
| `page` | 页码（从 1 开始）|
| `feature` | `0` = 全部 |

> **空账号返回 `ok:1` + 空 `list`**，不是错误，别误判。

### 4.6 首页时间线（关注的人）

```
GET /ajax/feed/unreadfriendstimeline?since_id=0&refresh=1&count=20
```

响应：`statuses[]`

| 参数 | 说明 |
|---|---|
| `since_id` | 首次 `0`（拉最新）；翻页用上次响应的 `since_id` |
| `refresh` | `1` |
| `count` | 条数 |

### 4.7 单条微博详情

```
GET /ajax/statuses/show?id=<mid>
```

⚠️ **此接口没有 `ok` 信封**，直接返回微博对象本身。

响应字段（节选）：`id` `idstr` `mid` `mblogid` `created_at` `text_raw` `text` `source`
`reposts_count` `comments_count` `attitudes_count` `user{}` `retweeted_status{}`（转发时存在）

> `mid` 即微博的 `idstr`，形如 `5353680452453036`。

### 4.8 评论

```
GET /ajax/statuses/buildComments
    ?is_reload=1&id=<mid>&is_show_bulletin=2&is_mix=0
    &count=20&max_id=0&max_id_type=0&flow=0
```

响应：`data[]`（评论对象）、`total_number`、`max_id`

| 参数 | 说明 |
|---|---|
| `flow` | `0` = 按热度，`1` = 按时间 |
| `max_id` | 翻页游标；首次 `0` |
| `count` | ⚠️ **实测被忽略**，固定返回 20 条 |

评论对象字段：`idstr` `created_at` `text_raw` `text` `like_counts` `floor_number`
`is_mblog_author`（是否作者） `user{}` `reply_comment{}`（回复某条时存在）

**翻页行为（实测，重要）：**

| 模式 | 翻页 |
|---|---|
| `flow=1`（按时间） | ✅ 用响应 `max_id` 传回即可翻页 |
| `flow=0`（按热度） | ❌ **返回的 `max_id` 传回拿不到第二页**（试过 `max_id_type` 0/1/2 均 0 条）；`page` 参数无效 |

> 需要完整评论列表时，**用 `flow=1` 逐页拉取**。

### 4.9 转发列表

```
GET /ajax/statuses/repostTimeline?id=<mid>&page=1
```

响应：`data[]`（微博对象）、`total_number`、`max_page`、`next_cursor`

✅ `page` 翻页有效。

### 4.10 搜索微博

```
GET /ajax/statuses/search?q=<关键词>&count=20&page=1
```

响应：`statuses[]`、`total_number`

| 参数 | 说明 |
|---|---|
| `q` | 关键词（需 URL 编码）|
| `page` | ✅ 有效（实测 page1/page2 结果不同）|

### 4.11 搜索联想词

```
GET /ajax/side/search?q=<关键词>
```

响应 `data.hotquery[]`：`{ suggestion, count, ... }`

### 4.12 关注列表

```
GET /ajax/profile/followContent?uid=<uid>
```

响应：`data.follows.users[]`、`data.total_number`

### 4.13 我的评论（发出的评论）✅ 已实测

```
GET /ajax/message/myCmt            # 第一页
GET /ajax/message/myCmt?max_id=<next_cursor>   # 翻页
```

响应：`data.comments[]`、`data.next_cursor`、`data.total_number`
（`data` 是**对象**，不是数组）

| 项 | 说明 |
|---|---|
| `next_cursor` | 翻页游标，实测是**数字**（如 `5131773927229958`），原样回传当 `max_id` |
| 首页 | `max_id` **不传**（传 `0` 未验证，别照抄 `buildComments` 的 `max_id=0` 习惯） |
| 每页条数 | 实测 20 条（首屏）；尾页可能更少（第 2 页 14 条）|
| `total_number` | 累计总数（实测 9499）|

**与 `buildComments` 的关键差异（踩过）：**

1. **两套游标**：这里用 `next_cursor`，`buildComments` 用 `max_id`，互不通用。
2. **`text_raw` 是空字符串**，正文只在 HTML 的 `text` 里。若按「优先 text_raw」的
   通用逻辑取文本，会拿到空串 → 整条评论**空白**。
3. **表情是 `<img alt="[微笑]">`**，不是文字。剥标签时必须先取 `alt` 再剥，
   反过来纯表情评论会渲染成空白（实测第一条评论只有一个 `[微笑]`）。
4. **每条都带 `status`**（被评论的原微博对象），可直接显示上下文 + 点进原微博，
   **不需要**再按 id 补拉详情。

同类端点：`/ajax/message/cmt`（**已实测**，见 4.14）、
`/ajax/message/attitudes`（赞）、`/ajax/message/msgList?type=...`（@我的等）。

### 4.14 回复我的评论 ✅ 已实测

```
GET /ajax/message/cmt                          # 第一页
GET /ajax/message/cmt?max_id=<next_cursor>     # 翻页
```

响应结构与 4.13 **完全一致**（`data.comments[]` + `next_cursor` + `total_number`），
可共用同一份解析代码。

**语义（实测结论，别望文生义）**：这个桶返回的是**「别人回复我发出的评论」** ——
连翻 3 页共 8 条，`reply_comment.user.id` **全部**是我本人。评论我微博的那类不走这里。

| 字段 | 说明 |
|---|---|
| `reply_comment{}` | **我原来那条评论**（`text` + `user`=我自己）|
| `status{}` | 原微博对象（可能因作者设置可见范围而内容为空，见下）|
| `rootid` | 该回复所在评论串的**根评论** id（分线程用，非必须）|
| `reply_original_text` | 原评论纯文本（可选，`reply_comment.text` 更全）|
| 每页条数 | ⚠️ **不固定**，实测 2 / 5 / 1 条 → 判断「还有下一页」**只能看 `next_cursor`**，不能用「不满 20 条即到头」 |

**坑**：`status.text` 可能是
`抱歉，根据作者设置的微博可见时间范围，此微博已不可见。` —— 作者设了可见范围。
UI 要把它当**占位文本正常显示**，不能当成空微博或解析失败。

**回复 TA 用哪个写接口**：对某条评论回复走

```
POST /ajax/comments/reply   （id=<原微博 mid>, cid=<这条回复的 id>, comment=<正文>）
```

即「回复某条评论」= `/ajax/comments/reply` + `cid`，**不是** `comments/create`。

### 已确认不可用的接口

| 接口 | 返回 |
|---|---|
| `/ajax/statuses/likeTimeline` | 你访问的地址不存在 |
| `/ajax/search/all` · `/ajax/search/statuses` | 你访问的地址不存在 |
| `/ajax/profile/getFriendList` | 你访问的地址不存在 |
| `/ajax/feed/group` | `ok=0`（分组列表）|
| `/ajax/remind/unread_count` | `ok=0`（未读数）|

---

## 5. 错误码

### 微博业务码

| 码 | 含义 |
|---|---|
| `ok:1` | 成功 |
| `ok:0` + `msg` | 业务失败（看 `msg`，如 `用户不存在(20003)`）|
| `10000` 系列 | 参数错误 |
| `20003` | 用户不存在 |

### HTTP / 网关

| 现象 | 含义 |
|---|---|
| `403 {"error":"Forbidden"}` | **缺 `Referer`** |
| `6102` | 被 APISIX 网关拦截（常见于 POST 用了 JSON 而非表单）|
| 重定向到 `login.sina.com.cn` | cookie 未发出或已失效 |

### 登录相关

| 码 | 含义 |
|---|---|
| `-20` | 登录名或密码错误 |
| `-10` | 手机号格式错误 |
| `8518` | 验证码错误 |
| `0 need mfa mfa_1` | 需网易易盾验证（风控）|

---

## 6. 已知坑位

| # | 坑 | 说明 |
|---|---|---|
| 1 | `Referer` 必填 | 缺失 → 403 |
| 2 | JDK `CookieManager` 不可用 | 自管 cookie + 自跟随重定向 |
| 3 | 跳转丢 cookie | 每跳都要收 `Set-Cookie`（用 curl `-c` 一路写回）|
| 4 | `statuses/show` 无 `ok` 信封 | 别套统一的 ok 检查 |
| 5 | 评论 `count` 被忽略 | 固定 20 条 |
| 6 | 评论按热度翻不了页 | 用 `flow=1` 按时间拉 |
| 7 | `mymblog` 空账号是 `ok:1` | 不是错误 |
| 8 | POST 必须表单编码 | JSON → 网关 6102 |
| 9 | 搜索无 `since_id`/`max_id` | 用 `page` |
| 10 | `mid` = `idstr` | 长整型字符串，别当 int 解析 |

---

## 7. 风控与工程建议

- **接口无契约** → 把接口路径**集中隔离在一个类**里，微博前端一改只动一处
- **写操作高度敏感** → 发博/点赞/评论务必节流（建议 ≥3s 间隔）+ 拟人化，否则易触发验证码/封禁
- **Cookie 30 天过期** → 失效时提示重新扫码（判定：`SUB` 没了，或响应跳转登录页）
- **不要并发轰炸** → 热搜等公开接口也建议限速
- **合规红线** → 仅自用；不做数据抓取、不做账号买卖、不公开发布

---

## 8. Kotlin 库用法

本仓库即一个可直接使用的 Kotlin 实现：

```bash
./build.sh          # 编译（Gradle wrapper 自动解析依赖）
./gradlew :cli:installDist
./cli/build/install/cli/bin/cli login      # 扫码登录
./cli/build/install/cli/bin/cli timeline 20
./cli/build/install/cli/bin/cli search 雷军
./cli/build/install/cli/bin/cli comments <mid>
```

作为库：

```kotlin
// core 不含平台 HTTP 实现，需由调用方注入引擎
// JVM 上用 JvmHttpEngine；Android 上用 OkHttpEngine
val client = WeiboClient(JvmHttpEngine())
val cookie = Path.of(System.getProperty("user.home"), ".weibo-client", "cookies.tsv")

if (!client.restore(cookie)) {
    client.auth.prepare()
    val qr = client.auth.createQr()          // qr.qrid / qr.imageUrl
    // …展示二维码，轮询 client.auth.poll(qr.qrid)…
    client.auth.complete(url)                 // 状态 CONFIRMED 时
    client.save(cookie)
}

client.homeTimeline(count = 20).forEach { println("${it.user?.screenName}: ${it.plainText}") }
client.search("雷军").take(5).forEach { println(it.plainText) }
client.hotBand().take(10).forEach { println("${it.realpos}. ${it.word}") }
```

**API 一览**

| 方法 | 说明 |
|---|---|
| `login` / `restore` / `save` / `isLoggedIn` | 会话管理 |
| `homeTimeline(count, sinceId)` | 首页时间线 |
| `myBlog(uid, page)` | 微博列表 |
| `profile(uid)` | 用户资料 |
| `following(uid)` | 关注列表 |
| `statusDetail(mid)` | 单条详情 |
| `comments(mid, count, maxId, flow)` | 评论 |
| `reposts(mid, page)` | 转发 |
| `search(q, count, page)` | 搜索 |
| `hotSearch()` / `hotBand()` | 热搜 |

---

## 参考实现

- `src/main/kotlin/com/cx/weibo/WeiboCore.kt` — 模型 + HTTP 层（自管 cookie）
- `src/main/kotlin/com/cx/weibo/WeiboAuth.kt` — 扫码登录
- `src/main/kotlin/com/cx/weibo/WeiboClient.kt` — **接口全集中于此**
- `src/main/kotlin/Main.kt` — CLI 演示

协议逆向过程与更多细节：`docs/WEIBO-WEB-API-INVENTORY.md`
