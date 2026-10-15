# weibo-client-kt

微博第三方客户端 —— **Rust 核心 + Flutter UI**（另保留一套 Jetpack Compose UI），基于实测验证的 **Web 接口**实现。

- ❌ 不碰私有 API（`api.weibo.cn`）
- ❌ 不碰签名（`s` 参数）
- ❌ 不需要 root / Xposed / frida
- ✅ 扫码登录 → 拿 `SUB` cookie → 调 `weibo.com/ajax/*`

> 背景：官方私有 API 被 `-105 客户端身份校验`（绑定 APK 签名）封死；第三方客户端 See微博 的登录契约也因微博废弃旧 OAuth 页面而失效。Web 接口是目前唯一干净且可持续的路。

---

## 当前特性

| 模块 | 功能 |
|---|---|
| 登录 | 扫码登录（轮询 + 二维码过期自动重取） |
| 信息流 | 首页（关注+推荐，游标翻页）· 关注（纯关注，页码翻页） |
| 微博卡片 | 转发块、九宫格配图、**点赞乐观 +1**（失败回滚）、长文展开 |
| 详情 | **3 个 tab：正文 / 评论 / 转发**；正文**默认展开全文**；评论可翻页、可回复（含二级评论） |
| 发布 | 发微博（公开 / 仅关注 / 仅自己）· 转发 · 评论 |
| 发现 | 搜索微博 · 热搜榜 |
| 个人 | 我的（资料 / 外观 / 设置 / 退出 / 我的微博）· 他人主页（资料 + TA 的微博） |
| 图片 | 全屏查看器（可缩放翻页）· **优先显示大图**（已缓存则直接用大图，不做模糊过渡） |
| 设置 | **关闭广告**（信息流不显示推广微博）· 清除微博缓存 |
| 外观 | 跟随系统 / 浅色 / 深色 |
| 缓存 | 信息流缓存（响应原文 + 游标）· 按微博 id 的单条缓存 |
| 交互 | 点标题栏（单击/双击）回到顶部 · 长列表虚拟化（见下） |

---

## 架构

```
┌────────────────────────────┐
│ flutter-app/  Flutter UI   │   ← 当前唯一 UI（Dart 16 文件）
└─────────────┬──────────────┘
              │ flutter_rust_bridge v2（生成 Dart 绑定）
┌─────────────▼────────────────────────────────────────────────┐
│ rust/  微博核心（Rust 8 文件 ≈2500 行，编译为 libweibo_core.so）│
│   http.rs            cookie 罐 + 自跟随重定向 + CSRF + UA      │
│   auth.rs            扫码登录（SSO v2）                        │
│   models.rs          数据模型（serde，严格建模）                │
│   client.rs          API 门面（接口全集中于此）                 │
│   reqwest_engine.rs  真实 HTTP 引擎（CLI / Flutter 用）         │
└─────────────┬─────────────────────────────────────────────────┘
              │ 同一个 core 还能被直接调用
       ┌──────▼───────┐
       │ weibo-cli    │  命令行前端（排查接口问题极好用，零 UI）
       └──────────────┘
```

**同一个核心，两个前端**：Flutter 与 CLI 共用完全相同的
HTTP / cookie / CSRF / 解析逻辑 —— 这也是为什么从 Compose 迁到 Flutter 时，
**`rust/` 一行都不用改**。

**绑定线**：`flutter-app/` → flutter_rust_bridge v2 → Dart。
（core 仍保留 UniFFI 导出，日后需要 Kotlin/Swift 绑定时可直接生成。）

> 历史：核心原先用 Kotlin 实现（`core/` 模块），后整体迁移到 Rust 并逐项验证；
> 早期的 Jetpack Compose UI（`app/` 模块）也已移除，UI 统一到 Flutter。
> 这些旧代码都在 git 历史里，可随时取回：
>
> ```bash
> git show <旧提交>:core/src/main/kotlin/com/cx/weibo/WeiboCore.kt
> git checkout 5ab483a -- app/     # 取回 Compose UI（5ab483a = 删除前的提交）
> ```

---

## 为什么用 Rust？—— 这个项目里实际得到的好处

**1. 一套核心喂三个前端，换 UI 不炸核心**
core 是独立的 Rust 库：Flutter、Compose、CLI 都调它。
本项目从 Compose 迁移到 Flutter 时，`rust/` **零改动** —— UI 框架换了，网络层、
cookie 罐、CSRF、重定向、解析全部原样复用。这是「核心与界面分离」最硬的收益。

**2. 能做跨语言差分验证（保证「换语言不换行为」）**
core 是能独立在主机上跑的库，所以可以拿**同一输入**去比对「原 Kotlin 实现」和
「Rust 实现」的输出：本项目做了 **22 项单元测试 + 28（工具）/ 42（HTTP）/ 57（Client）
项跨语言差分**，全绿才收工。如果核心代码和 UI 混在一起，这种验证根本做不了。

**3. 解析严格，错误可诊断**
用 `serde` 严格建模 + 自定义错误类型，解析失败时会带出**是哪个字段、原文前 120 字符**，
而不是静默变成 `null`。本项目就靠它抓出了 `isAd` 字段多态（bool/number/string 混用）、
`since_id` 传空串等真问题 —— 在 Gson 那套里这些往往会安静地变成 null，很难发现。

**4. 无 GC，内存与延迟更可控**
网络请求 + JSON 解析这条热点路径没有 GC 停顿，对移动端更友好。

**5. 真正的 native 产物，不绑 JVM**
编译出 `.so`，Android / iOS / 桌面 / 服务端都能用。同时保留了 **CLI 这种零 UI 形态** ——
接口出问题时用 CLI 直接在主机上复现，比在手机上抓 log 快一个数量级。

**6. 零平台胶水**
HTTP 引擎用 `reqwest` + `rustls` + **内置 Mozilla 根证书（webpki-roots）**，
Android 上不需要任何 JNI / TLS 初始化。
（对比踩坑：`reqwest` 默认的 `rustls-platform-verifier` 在 Android 必须先初始化，
否则后台线程 panic，上层只能看到一句没有信息量的 `event loop thread panicked`。）

**7. FFI 边界很薄**
对外只暴露「入参 + DTO」。cookie 罐、CSRF 双提交、跨跳转吸收 `Set-Cookie`
这些脏活全留在 Rust 里，UI 侧一次调用就够。

---

## 为什么用 Flutter？—— 这个项目里实际得到的好处

**1. 热重载，UI 迭代快一个量级**
改一个样式不用重新编 APK（本项目一次 release 构建约 1 分钟），
热重载秒级看到效果。这个项目 UI 反馈迭代非常多，收益最直观。

**2. 一套 UI 多平台**
同一份 Dart 代码可编到 Android / iOS / 桌面 / Web。
原来的 Compose 版只能 Android —— 想上 iOS 得把 UI 重写一遍。

**3. 长列表天然虚拟化（用户问过这点）**
`ListView.builder` / `ListView.separated` 本身就是**懒加载**：
只构建视口内 **± cacheExtent（默认 250px）** 的元素，滚出范围的 element
被**回收复用**，所以 CPU / 内存开销被**视口大小**限制，**与列表总长度无关** ——
和前端虚拟列表是同一个思路，不需要额外配置。

**4. 自绘渲染（Skia/Impeller），跨设备一致**
不依赖平台控件，不受各 OEM 主题/控件差异影响，同一套样式在哪里都一样。

**5. 接线成本低**
`cached_network_image`（图片磁盘缓存）、`flutter_cache_manager`（缓存命中查询）、
`shared_preferences`（KV 存储）、`path_provider`（私有目录）直接覆盖了常见需求。

**6. 接 Rust 很方便**
`flutter_rust_bridge` 直接生成 Dart 绑定，同步函数（如 URL 处理）还能标成 `sync`，
在 `build()` 里直接调用。

---

## Rust + Flutter 组合的收益（小结）

| 关注点 | 放在哪 | 得到什么 |
|---|---|---|
| HTTP / cookie / CSRF / 重定向 / 解析 | **Rust** | native 性能、无 GC、严格类型、可差分验证、多端复用 |
| 界面 / 交互 / 动画 / 主题 | **Flutter** | 热重载、跨平台、声明式 UI、列表虚拟化 |
| 两者之间 | 桥接层（FRB / UniFFI） | 只传 DTO，边界薄；换 UI 框架不影响核心 |

> 一句话：**把「不能错、要复用」的放 Rust，把「常改、要好看」的放 Flutter。**

---

## 快速开始

### CLI（最快验证接口）

```bash
cd rust
cargo build --release
./target/release/weibo-cli login      # 扫码登录，自动保存会话
./target/release/weibo-cli whoami     # 看当前账号
./target/release/weibo-cli timeline   # 首页时间线
./target/release/weibo-cli hot        # 热搜榜
```

会话保存在 `~/.weibo-client/cookies.tsv`（有效期约 30 天，过期重新 `login`）。

### Flutter（当前主力 UI）

```bash
cd flutter-app
flutter build apk --release --split-per-abi   # 按 ABI 拆分（单包更小）
flutter build apk --release                   # 全架构包
```

Gradle 会通过 cargokit 自动完成：`cargo build`（交叉编译 3 个 ABI）→ 打进 APK。

> **包名/签名**：UI 用 `com.cx.weibo.android` + debug keystore
> （复用 debug 密钥签 release，方便直接安装体验）。
> cookie 存在 `filesDir/cookies.tsv`，同包名**覆盖安装后登录态可直接继承**，不用重新扫码。

---

## CLI 命令

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

---

## 本地缓存设计

两层，思路继承自早期 Compose 版的 `FeedCache`：

**① 信息流缓存**（`files/feed/<feed>.json`）
- 存**服务端响应原文**（一页一条）+ **翻页游标**
- 为什么存原文而不是解析结果：重开时用 core 的 `parseTimelineRaw` 还原，
  走的是**和网络路径完全相同**的解析代码 —— core 改了字段，老缓存依然能正确解析
- **游标必须一起存**：只存正文不存游标，「加载更多」就断链了
- 进页面先用缓存渲染（秒开）→ 再回网络刷新；网络失败不覆盖已显示内容

**② 按微博 id 的单条缓存**（`files/status/<微博id>.json`）
- **「某条微博有没有缓存」= 文件是否存在** —— 用 id 当文件名最省事：
  零索引、O(1) 判断，也不会出现「索引和文件不同步」的烂账
- 详情页先用缓存渲染，再回网络刷新并存原文

两处都是**原子写**（先写 `.tmp` 再 rename），写一半被杀进程也不会留坏文件。

---

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

**6. UA 必须与端点语义一致**
本项目端点全是 `weibo.com/ajax/*`（**桌面网页端**接口），所以用**桌面 Chrome UA**。
实测把 UA 换成 Android Chrome 后会**静默掉回登录页**（未登录接口正常，带会话的接口失效）——
UA 声称 Android 却打桌面接口，是真实客户端不会出现的组合。
Android UA 留作常量（`ANDROID_UA`）便于切换。
> 关于风控：真正有效的是**控制请求频率 + 复用同一会话**，而不是改 UA。

**7. Rust panic 在 Android 默认不可见**
只写 stderr，会被丢弃。已挂 panic hook 通过 `__android_log_write` 打进 logcat
（tag `weibo_rust`）—— 上面第 6 条和 TLS 初始化问题都是靠它才定位到真因。

**8. FFI 边界要只传 DTO**
`flutter_rust_bridge` 对**外部 crate 的类型**默认生成 opaque 句柄（Dart 读不到字段），
所以桥接层显式定义 DTO；错误也转成桥接层自己的类型，否则 Dart 侧读不到失败原因。

**9. 「头部 + 列表」不要做嵌套滚动**
详情页最初用 `NestedScrollView`（正文当 header、评论/转发当内层列表），
内外两层滚动 + 内层 `RefreshIndicator` 互相打架 → 出现「下滑之后上不去、反而触发刷新」。
最终改成 **3 个平级 tab**，各自独立列表，问题从结构上消失。
（也不能把高度不可控的内容直接放进 `Column` + `Expanded` —— 会把它挤成 0 高度。）

**10. 详情页正文默认展开**
列表里长文默认折叠（省流量），详情页则自动拉全文直接展示。

---

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
- 首页时间线的 `since_id` **不能传空串**（服务端要求 long），第一页归一化为 `"0"`。
- 评论：`count` 参数被忽略（固定 20 条）；**按热度（flow=0）翻不了页**，要完整列表请用 `flow=1`（按时间）。
- 搜索结果没有 `since_id`/`max_id`，翻页用 `page` 参数。
- `mymblog` 对**空账号**返回 `ok:1` + 空 `list`（不是错误），不要误判为失败。
- 长文会被服务端截断（`isLongText=true`），全文需单独调 `longtext`。
- 配图 URL 要区分尺寸：列表用 `bmiddle`（中等），**全屏查看器必须换成 `/large/`**
  （`weibo_image_large` 做 CDN 尺寸段替换），否则放大会糊。

## 文档

- **[API.md](API.md)** —— 完整的第三方接入文档（认证流程 / 全部接口 / 错误码 / 坑位），供他人直接用
- `docs/WEIBO-WEB-API-INVENTORY.md` —— 协议逆向存档
- `docs/WEIBO-H5-ANALYSIS.md` —— 登录协议分析

## 风险

- **接口无契约**：微博前端更新可能导致接口失效（已做接口层隔离便于修补）
- **风控**：Web 端对自动化敏感，写操作尤其要节流；建议保持单会话、无并发
- **Cookie 30 天过期**：需重新扫码
- **合规**：仅限自用 / 学习，公开发布违反平台协议

## 环境依赖

| 用途 | 依赖 |
|---|---|
| Rust 核心 + CLI | rustup（本仓库验证于 rustc 1.99.0） |
| Android 交叉编译 | Android NDK 30.0.16248370 + `cargo-ndk` |
| Flutter 构建 | Flutter SDK（本仓库验证于 3.47.7 / Dart 3.13.5） |
| Flutter↔Rust 绑定 | `flutter_rust_bridge_codegen` 2.13.0 |

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk
cargo install flutter_rust_bridge_codegen --version 2.13.0 --locked
```

> 构建 Rust / Gradle / Flutter 依赖时若网络受限，请自行配置代理。
