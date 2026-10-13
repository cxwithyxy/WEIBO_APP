# 微博 Android 客户端 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把已验证的微博 Web 协议做成一个功能完整的 Android 客户端（Jetpack Compose）：能扫码登录、刷时间线、看微博详情与评论、搜索、看热搜、管理账号。

**Architecture:** Gradle 多模块。`core` 承载**全部已验证的协议逻辑**（平台无关：模型 / cookie 罐 / API 门面 / 登录流程），HTTP 通过 `HttpEngine` 接口注入。`cli` 提供 JVM 引擎（`java.net.http`，即现有已验证实现）；`app` 是 Android Compose 应用，提供 OkHttp 引擎。**这样"逆向得来的宝贵逻辑"只写一遍，两个前端共用。**

**Tech Stack:** Kotlin 2.0.21 · AGP 8.7.0 · Gradle 8.9(wrapper) · Jetpack Compose (BOM 2024.09.00) · Material3 · Coroutines · Navigation-Compose · Coil 3 · OkHttp 4.12 · Gson 2.11

---

## 0. 现状与环境（已实测）

| 项 | 实测结果 | 影响 |
|---|---|---|
| JDK | 21.0.11 | ✓ |
| Kotlin 编译器 | `~/kotlinc`（手工搭建） | 改用 Gradle 后不再需要 |
| Android SDK | `/home/cx/Android/Sdk`，platforms 29/33/34/35/36，build-tools 34.0.0/35.0.0 | ✓ |
| 全局 Gradle | **4.4.1（2012 年）** | ⚠️ 太老，必须用 wrapper |
| Google Maven | AGP 8.7.0 ✓200、Compose BOM ✓200 | ✓ |
| Maven Central | OkHttp ✓200 | ✓ |
| Android Studio | 未安装 | 全命令行构建 |
| 目标设备 | `172.27.34.40:5555`，API 35 / Android 15 / x86_64 | 直接装机测试 |
| 磁盘 | 276G 可用 | ✓ |

### 关键约束

1. **`java.net.http.HttpClient` 在 Android 上不存在** —— 现有 `WeiboHttp` 直接依赖它。必须抽象。
2. **Gradle 4.4.1 无法解析新 Kotlin DSL** —— wrapper 必须在**空目录**里生成再拷入。
3. **无 Android Studio** —— 构建链必须是 `./gradlew assembleDebug` + `adb install`。
4. **`java.nio.file` 需要 API 26+** —— `minSdk` 定为 **26**。

### 已具备的资产（`weibo-client-kt` 现有代码）

| 文件 | 内容 | 迁移去向 |
|---|---|---|
| `WeiboCore.kt` | 模型 + `WeiboHttp`（ cookie 罐 + 重定向跟随） | `core/` |
| `WeiboAuth.kt` | 扫码登录 5 步流程 | `core/` |
| `WeiboClient.kt` | 12 个 API 门面 | `core/` |
| `Main.kt` | CLI 11 个命令 | `cli/` |
| `docs/`, `API.md` | 协议文档 | 保留 |

> ⚠️ 这些逻辑是**实测验证过的**（whoami/timeline/hot/detail/comments/reposts/search/user 全部真实跑通）。
> **迁移的第一原则：不许改坏。** Phase 1 结束必须跑回归验证。

---

## 1. 功能范围

### MVP（Phase 1–6，用户"完整客户端"的最小闭环）

| 页面 | 功能 |
|---|---|
| 登录 | 二维码展示 + 轮询 + 成功落 cookie |
| 首页时间线 | 列表 / 下拉刷新 / 触底加载更多 / 图片 |
| 微博详情 | 正文 / 九宫格图 / 转发数 / 评论列表（含翻页） |
| 搜索 | 关键词搜索 + 结果列表 |
| 热搜 | 榜单列表，点词条进搜索 |
| 我的 | 资料卡 / 我的微博列表 / 登出 |

### 后续（MVP 之后，各自单独出计划）

| 方向 | 内容 |
|---|---|
| 写操作 | 发博 / 转发 / 评论 / 点赞（**必须节流 ≥3s + 拟人化**） |
| 体验 | 图片查看器（缩放/滑动）/ 深色模式 / 骨架屏 |
| 数据 | 本地缓存离线可读 / 草稿箱 |
| 账号 | 多账号切换 |

### 明确不做（YAGNI）

- 私信 / 直播 / 视频上传（Web 接口不支持或风险过高）
- 实时推送（只能轮询，MVP 不做长连接）
- 后台服务 / 小部件

---

## 2. 目录结构（改造后）

```
weibo-client-kt/
├── settings.gradle.kts
├── build.gradle.kts
├── gradle.properties
├── gradlew  gradlew.bat
├── gradle/wrapper/
├── core/                                  ← 平台无关协议核心
│   ├── build.gradle.kts
│   └── src/main/kotlin/com/cx/weibo/
│       ├── http/
│       │   ├── HttpEngine.kt              接口 + RawRequest/RawResponse
│       │   └── CookieJar.kt               cookie 罐（从 WeiboHttp 抽出）
│       ├── model/                         User / Status / Comment / HotItem ...
│       ├── WeiboHttp.kt                   重定向跟随 + cookie 注入（依赖 HttpEngine）
│       ├── WeiboAuth.kt                   扫码登录
│       └── WeiboClient.kt                 12 个 API 门面
├── cli/                                   ← 现有 CLI（保持可用）
│   ├── build.gradle.kts
│   └── src/main/kotlin/com/cx/weibo/
│       ├── cli/Main.kt                    11 个命令
│       └── http/JvmHttpEngine.kt          java.net.http 实现
├── app/                                   ← Android 应用
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── kotlin/com/cx/weibo/android/
│       │   ├── MainActivity.kt
│       │   ├── http/OkHttpEngine.kt
│       │   ├── data/                      仓库层 + cookie 持久化
│       │   ├── ui/                        各页面 Composable
│       │   └── ui/theme/
│       └── res/
├── API.md  README.md
└── docs/
```

**依赖方向（单向，不许反向）：**

```
app ──┐
      ├──> core
cli ──┘
core 不依赖任何前端
```

---

## 3. 阶段划分

| 阶段 | 目标 | 完成判据 |
|---|---|---|
| **P1 工程化** | Gradle 多模块 + HTTP 抽象 | **CLI 全部命令回归通过**（与改造前输出一致） |
| **P2 Android 骨架** | 空壳 App 能装能跑 | 设备上看到 Compose "Hello" |
| **P3 登录** | 扫码登录页 | 扫真码，App 内进入主界面 |
| **P4 时间线** | 首页列表 | 真实时间线 + 刷新 + 分页 |
| **P5 详情/评论** | 微博详情页 | 正文 + 图 + 评论翻页 |
| **P6 搜索/热搜/我的** | 补齐剩余页 | 三页均真实数据 |

> 每个阶段独立可测、独立提交。**P1 完成后再单独细化 P2 的计划**（避免过早细化被推翻）。

---

## 4. Phase 1 详细任务

**Phase 1 目标：把现有单模块 Kotlin 项目改造成 Gradle 多模块，抽出 HTTP 引擎接口，CLI 保持 100% 可用。**

**验收命令（改造前后输出必须一致）：**

```bash
./gradlew :cli:installDist
./cli/build/install/cli/bin/cli whoami     # → uid/昵称/关注粉丝
./cli/build/install/cli/bin/cli hot        # → 热搜榜
./cli/build/install/cli/bin/cli timeline 5 # → 时间线
```

---

### Task 1: 生成 Gradle wrapper（在空目录，避开老 Gradle）

**Files:**
- Create: `gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar`, `gradle/wrapper/gradle-wrapper.properties`

- [ ] **Step 1: 在临时空目录生成 8.9 wrapper**

```bash
mkdir -p /tmp/wrapgen && cd /tmp/wrapgen
gradle wrapper --gradle-version 8.9 --distribution-type bin
ls -R
```
Expected: 生成 `gradlew`、`gradlew.bat`、`gradle/wrapper/{gradle-wrapper.jar,gradle-wrapper.properties}`

- [ ] **Step 2: 拷入项目**

```bash
cd /home/cx/.openclaw/workspace/weibo-client-kt
cp -r /tmp/wrapgen/gradlew /tmp/wrapgen/gradlew.bat /tmp/wrapgen/gradle .
chmod +x gradlew
grep distributionUrl gradle/wrapper/gradle-wrapper.properties
```
Expected: `distributionUrl=...gradle-8.9-bin.zip`

- [ ] **Step 3: 验证 wrapper 可下载 Gradle（首次约 130MB，耗时较长）**

```bash
./gradlew --version
```
Expected: 输出 `Gradle 8.9`（**不是** 4.4.1）

- [ ] **Step 4: 提交**

```bash
git add gradlew gradlew.bat gradle/
git commit -m "chore: add Gradle 8.9 wrapper"
```

---

### Task 2: 建立多模块骨架

**Files:**
- Create: `settings.gradle.kts`, `build.gradle.kts`, `gradle.properties`
- Create: `core/build.gradle.kts`, `cli/build.gradle.kts`

- [ ] **Step 1: 写 settings.gradle.kts**

```kotlin
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "weibo-client"
include(":core", ":cli")
```
> 注意：`app` 模块在 Phase 2 才加入 include。

- [ ] **Step 2: 写根 build.gradle.kts**

```kotlin
plugins {
    kotlin("jvm") version "2.0.21" apply false
}
```

- [ ] **Step 3: 写 gradle.properties**

```properties
org.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8
kotlin.code.style=official
org.gradle.parallel=true
org.gradle.caching=true
```

- [ ] **Step 4: 写 core/build.gradle.kts**

```kotlin
plugins { kotlin("jvm") }

kotlin { jvmToolchain(17) }

dependencies {
    implementation("com.google.code.gson:gson:2.11.0")
}
```

- [ ] **Step 5: 写 cli/build.gradle.kts**

```kotlin
plugins {
    kotlin("jvm")
    application
}

kotlin { jvmToolchain(17) }

dependencies {
    implementation(project(":core"))
    implementation("com.google.code.gson:gson:2.11.0")
}

application {
    mainClass.set("com.cx.weibo.cli.MainKt")
    applicationName = "cli"
}
```

- [ ] **Step 6: 提交**

```bash
git add settings.gradle.kts build.gradle.kts gradle.properties core/build.gradle.kts cli/build.gradle.kts
git commit -m "build: multi-module skeleton (core + cli)"
```

---

### Task 3: 抽出 HTTP 引擎接口

**Files:**
- Create: `core/src/main/kotlin/com/cx/weibo/http/HttpEngine.kt`

- [ ] **Step 1: 写接口与数据类**

```kotlin
package com.cx.weibo.http

/**
 * 一次「不跟随重定向、不管理 cookie」的原始请求。
 * POST 的 body 必须已按 application/x-www-form-urlencoded 编码。
 */
data class RawRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray? = null,
)

/** 原始响应。引擎**不得**跟随重定向、不得管理 cookie、不得重试。 */
class RawResponse(
    val status: Int,
    headers: Map<String, List<String>>,
    val body: ByteArray,
) {
    private val lower: Map<String, List<String>> =
        headers.entries.associate { it.key.lowercase() to it.value }

    fun header(name: String): String? = lower[name.lowercase()]?.firstOrNull()
    fun headerValues(name: String): List<String> = lower[name.lowercase()] ?: emptyList()

    val bodyText: String get() = String(body, Charsets.UTF_8)
}

/**
 * 平台 HTTP 引擎。
 *
 * 实现约定（非常重要，core 的重定向/cookie 逻辑依赖它）：
 *  - **不跟随重定向**，原样返回 3xx 与 Location
 *  - **不管理 cookie**，原样回传所有 Set-Cookie
 *  - **不自动重试**
 */
interface HttpEngine {
    fun execute(request: RawRequest): RawResponse
}
```

- [ ] **Step 2: 编译验证**

```bash
./gradlew :core:compileKotlin
```
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 3: 提交**

```bash
git add core/src/main/kotlin/com/cx/weibo/http/HttpEngine.kt
git commit -m "feat(core): add platform-agnostic HttpEngine abstraction"
```

---

### Task 4: 迁移协议核心到 core 模块（保留全部逻辑）

**Files:**
- Move: `src/main/kotlin/com/cx/weibo/WeiboCore.kt` → `core/src/main/kotlin/com/cx/weibo/WeiboCore.kt`
- Move: `src/main/kotlin/com/cx/weibo/WeiboAuth.kt`  → `core/src/main/kotlin/com/cx/weibo/WeiboAuth.kt`
- Move: `src/main/kotlin/com/cx/weibo/WeiboClient.kt` → `core/src/main/kotlin/com/cx/weibo/WeiboClient.kt`
- Move: `src/main/kotlin/Main.kt` → `cli/src/main/kotlin/com/cx/weibo/cli/Main.kt`

- [ ] **Step 1: 移动文件**

```bash
cd /home/cx/.openclaw/workspace/weibo-client-kt
mkdir -p core/src/main/kotlin/com/cx/weibo cli/src/main/kotlin/com/cx/weibo/cli
git mv src/main/kotlin/com/cx/weibo/WeiboCore.kt   core/src/main/kotlin/com/cx/weibo/
git mv src/main/kotlin/com/cx/weibo/WeiboAuth.kt   core/src/main/kotlin/com/cx/weibo/
git mv src/main/kotlin/com/cx/weibo/WeiboClient.kt core/src/main/kotlin/com/cx/weibo/
git mv src/main/kotlin/Main.kt                     cli/src/main/kotlin/com/cx/weibo/cli/
rmdir -p src/main/kotlin/com/cx/weibo 2>/dev/null
rmdir -p src/main/kotlin 2>/dev/null
```

- [ ] **Step 2: 给 core 加 `.gitignore` 兜底（确认无残留）**

```bash
find src -type f 2>/dev/null && echo "⚠️ 有残留" || echo "✓ src/ 已清空"
```

- [ ] **Step 3: 提交（仅移动，不改内容）**

```bash
git add -A
git commit -m "refactor: move protocol core into :core and CLI into :cli"
```

---

### Task 5: WeiboHttp 改为依赖 HttpEngine

**Files:**
- Modify: `core/src/main/kotlin/com/cx/weibo/WeiboCore.kt`

- [ ] **Step 1: 改类签名（注入引擎）**

```kotlin
class WeiboHttp(
    private val engine: HttpEngine,
    val ua: String = DESKTOP_UA,
) {
```

- [ ] **Step 2: 替换 `raw()` 的实现（保留原有头构造逻辑，只换发送与吸收）**

```kotlin
    private fun raw(url: String, method: String, body: String?, referer: String?, ajax: Boolean): Res {
        val uri = URI.create(url)
        val headers = buildMap {
            put("User-Agent", ua)
            put("Accept-Language", "zh-CN,zh;q=0.9")
            put(
                "Accept",
                if (ajax) "application/json, text/plain, */*"
                else "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
            )
            cookieHeader(uri.host).takeIf { it.isNotEmpty() }?.let { put("Cookie", it) }
            referer?.let { put("Referer", it) }
            if (ajax) put("X-Requested-With", "XMLHttpRequest")
            if (body != null) put("Content-Type", "application/x-www-form-urlencoded")
        }
        val resp = engine.execute(
            RawRequest(url, method, headers, body?.toByteArray(StandardCharsets.UTF_8))
        )
        absorb(uri.host, resp)
        return Res(resp.status, resp.header("Location"), resp.bodyText)
    }
```

- [ ] **Step 3: 改 `absorb()` 接收 `RawResponse`**

```kotlin
    private fun absorb(host: String, resp: RawResponse) {
        resp.headerValues("Set-Cookie").forEach { raw ->
            // …以下解析逻辑与原来完全一致（勿改）
        }
    }
```

- [ ] **Step 4: 删除 `client` / `HttpClient` 字段与相关 import**

```bash
grep -n "HttpClient\|java.net.http" core/src/main/kotlin/com/cx/weibo/WeiboCore.kt
```
Expected: **无输出**（core 中不再引用 `java.net.http`）

- [ ] **Step 5: 编译**

```bash
./gradlew :core:compileKotlin
```
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 6: 提交**

```bash
git add core/
git commit -m "refactor(core): WeiboHttp now depends on HttpEngine, not java.net.http"
```

---

### Task 6: cli 提供 JVM 引擎并接上

**Files:**
- Create: `cli/src/main/kotlin/com/cx/weibo/http/JvmHttpEngine.kt`
- Modify: `cli/src/main/kotlin/com/cx/weibo/cli/Main.kt`

- [ ] **Step 1: 写 JvmHttpEngine（原实现的搬家）**

```kotlin
package com.cx.weibo.http

import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.TimeUnit

/**
 * JVM 引擎（java.net.http）。
 * 刻意关闭自动重定向，交由 core 的 WeiboHttp 处理——
 * 因为它需要每跳都吸收 Set-Cookie。
 */
class JvmHttpEngine : HttpEngine {

    private val client: HttpClient = HttpClient.newBuilder()
        .followRedirects(HttpClient.Redirect.NEVER)
        .connectTimeout(Duration.ofSeconds(20))
        .build()

    override fun execute(request: RawRequest): RawResponse {
        val b = HttpRequest.newBuilder(URI.create(request.url))
            .timeout(Duration.ofSeconds(25))
        request.headers.forEach { (k, v) -> b.header(k, v) }
        b.method(
            request.method,
            request.body?.let { HttpRequest.BodyPublishers.ofByteArray(it) }
                ?: HttpRequest.BodyPublishers.noBody()
        )
        val r = client.send(b.build(), HttpResponse.BodyHandlers.ofByteArray())
        return RawResponse(r.statusCode(), r.headers().map(), r.body())
    }
}
```

- [ ] **Step 2: Main.kt 注入引擎**

```kotlin
val client = WeiboClient(JvmHttpEngine())
```
（`WeiboClient` 构造函数改为 `class WeiboClient(engine: HttpEngine)`，内部 `val http = WeiboHttp(engine)`）

- [ ] **Step 3: 构建 CLI 发行版**

```bash
./gradlew :cli:installDist
```
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 4: 提交**

```bash
git add cli/
git commit -m "feat(cli): add JvmHttpEngine and wire it into CLI"
```

---

### Task 7: 回归验证（本阶段最关键一步）

**Files:** 无（仅验证）

- [ ] **Step 1: 恢复会话 cookie**

```bash
mkdir -p ~/.weibo-client
cp /tmp/weibo-h5/cj.txt ~/.weibo-client/cookies.tsv   # 若文件已不存在，改用 ./cli/build/install/cli/bin/cli login 扫码
```

- [ ] **Step 2: 跑全量命令，逐条比对**

```bash
CLI=./cli/build/install/cli/bin/cli
$CLI whoami
$CLI hot
$CLI band | head -5
$CLI timeline 5
$CLI meblog
$CLI following | head -5
$CLI search 雷军 | head -10
$CLI detail <一个真实mid>
$CLI comments <一个真实mid> 5
$CLI reposts <一个真实mid> | head -10
$CLI user <某个uid> | head -5
```
Expected: **输出与改造前一致**（真实数据，非报错）

- [ ] **Step 3: 若任何一条退化 → 立即定位修复，不得进入 Phase 2**

常见退化点：
- `403 Forbidden` → 头构造漏了 `Referer`
- 被重定向登录页 → cookie 没注入（`cookieHeader` 的 host 匹配）
- 登录丢失 → 重定向跟随中没吸收 `Set-Cookie`

- [ ] **Step 4: 记录回归结果并提交**

```bash
git commit --allow-empty -m "test: Phase 1 regression — all CLI commands verified against live API"
```

---

## 5. Phase 2 起（后续需单独细化计划）

### Phase 2: Android 骨架
- `app/build.gradle.kts`（AGP 8.7.0 + Compose + kotlin-compose 插件）
- `AndroidManifest.xml`（`INTERNET` 权限、明文 HTTP 不需要）
- `MainActivity` + 空白 Compose 主题
- `OkHttpEngine`（实现 `HttpEngine`）
- 验收：`./gradlew :app:assembleDebug` → `adb install` → 设备上看到界面

### Phase 3: 扫码登录
- `LoginViewModel` + `LoginScreen`：取码 → 显示 QR → 轮询 → 成功
- cookie 持久化到 `context.filesDir/cookies.tsv`（复用 core 的 save/load）
- 验收：真机扫码后进入主界面

### Phase 4: 时间线
- `TimelineViewModel`（分页 / 刷新）+ `TimelineScreen`（LazyColumn）
- 图片加载用 Coil
- 验收：滚动到底加载更多

### Phase 5: 详情 + 评论
- `StatusDetailScreen`：正文 + 九宫格 + 评论列表（`flow=1` 翻页）
- 验收：点进一条微博，评论能翻页

### Phase 6: 搜索 / 热搜 / 我的
- 三页 + 底部导航
- 验收：三页均真实数据

---

## 6. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **接口无契约**（微博改前端） | 功能突然挂 | 接口已隔离在 `WeiboClient.kt` 一处，改一处即可 |
| cookie 30 天过期 | 用户被登出 | App 检测到未登录自动跳登录页 |
| 写操作触发风控 | 封号 | MVP 不做写操作；后续做必须 ≥3s 节流 |
| 首次 Gradle 下载慢 | 构建卡住 | wrapper 走直连（已测 200）；必要时挂代理 `127.0.0.1:10809` |
| 老 Gradle 4.4.1 污染 | 构建报错 | 全程只用 `./gradlew`，**绝不**用系统 `gradle` |
| 迁移改坏已验证逻辑 | 白干 | Phase 1 强制回归验证，不过不进 Phase 2 |
| 合规 | 法律风险 | 仅自用/学习，不公开发布、不抓数据 |

---

## 7. 自检（Self-Review）

- **范围覆盖**：登录/时间线/详情/评论/搜索/热搜/我的 → P3–P6 均有对应任务 ✓
- **占位符扫描**：无 TBD / TODO；Phase 1 每步含可执行命令与完整代码 ✓
- **类型一致性**：`HttpEngine.execute(RawRequest): RawResponse` 在 Task 3 定义，Task 5/6 使用一致；`WeiboHttp(engine, ua)` 签名在 Task 5/6 一致 ✓
- **未定义引用**：`absorb()` 明确标注"解析逻辑保持原样"；`Res` 为原有内部类 ✓

---

## 8. 执行方式

Phase 1 完成后提供两个选项：

1. **子代理驱动（推荐）** —— 每个 Task 派一个新子代理，任务间我审查，迭代快
2. **本会话内执行** —— 批量执行 + 检查点

然后 Phase 2 起，每阶段开工前先细化成同等粒度的计划。
