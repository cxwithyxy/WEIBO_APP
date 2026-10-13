# 官方微博 APK 分析笔记（REA）

> 2026-10-13 · 目标：`apk_variants/weibo_official.apk`

## 0. 目标身份

| 项 | 值 |
|---|---|
| 包名 | `com.sina.weibo` |
| 版本 | 16.6.1 (code 8007) |
| SHA-256 | `0ac02386a279a16eac5696ce0a80d06e80398a0d645750da02790b227026fd69` |
| 大小 | 183,714,497 B |
| minSdk / targetSdk | 21 / 35 |
| dex | 19 个（classes.dex ~ classes19.dex） |
| 类数 | 61,651 |
| 资源数 | 22,126 |
| arm64 so | 81 个 |

## 1. 工具链状态

- REA 6.4.0 MCP（OpenClaw 注册名 `rea`），env 增加：
  - `REA_JADX_MCP_JAR=/home/cx/.local/share/jadx-headless-mcp/jadx-headless-mcp-0.7.1-all.jar`
  - `JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64`
- JADX headless MCP 引擎 v0.7.1（jar SHA-256 `6e5eacf5…3ff75`，与官方 `.sha256` 一致）
- 本机：JDK 21、apktool 2.7.0、jadx CLI 1.5.2（`caij.see/jadx/bin/jadx`）
- ✅ `inspect_android_package` / `inspect_android_class` / `inspect_android_method` 可用
- ❌ `search_android_classes` 在本包**失败**：REA 校验报
  `JADX class inventory is duplicated or differs from the loaded class count`
  （推测：重度混淆 + 多 dex 重名）→ 类名发现需绕过（见 §4）

## 2. 架构判断（重要）

**官方微博已是 原生 + Flutter 混合**：

- `meta-data android:name="flutterEmbedding" android:value="2"`
- `lib/arm64-v8a/libapp.so` 9.4 MB = Dart AOT snapshot（业务逻辑大头在这里）
- `libflutter.so` 11.3 MB、`libwbcube-skia.so`、`libwb3dmodel.so`

→ **dex/jadx 只能看到原生那半边**。Flutter 那半边需要 Dart snapshot 逆向工具（如 blutter），REA 不覆盖。

### 网络/安全相关 so

| so | 说明 |
|---|---|
| `libtnet-4.0.0.so` | 腾讯 TNet 网络栈 |
| `libhttpdns.so` | HTTPDNS |
| `libprotobuf.so` | protobuf |
| `libdexvmp.so` | **DEX VMP 保护**（部分类被抽成 native） |
| `libshadowhook.so` / `libshadowhook_nothing.so` | inline hook（PLT/GOT） |
| `libed25519.so` | 签名算法线索 |

## 3. 接口层线索（dex 字符串提取）

主要 host 分布：`m.weibo.cn`(61)、`h5.sinaimg.cn`(35)、`weibo.cn`(18)、`weibo.com`(16)、
`new.vip.weibo.cn`(14)、`service.account.weibo.com`(13)、`api.weibo.cn`(10)、`ai.s.weibo.com`(10)、
`security.weibo.com`(9)

`api.weibo.cn/2/...` 抽样：

```
https://api.weibo.cn/2/client/tabbar
https://api.weibo.cn/2/push/register
https://api.weibo.cn/2/multimedia/multidiscovery
https://api.weibo.cn/2/!/multimedia/dispatch
https://api.weibo.cn/2/!/edm/vivo_focusstar
https://api.weibo.cn/2/!/st_videos/tiny/effect/sdk_source_list
https://api.weibo.cn/2/map/static?longitude=%s&latitude=%s&width=%d&height=%d&poiid=%s&source=%s
https://daziban.api.weibo.cn/daziban/portal.php?ct=util&a=download&type=setting
```

其他关键串：

- `gsid_CTandWM=` ← **和 caij.see SeePatch 注入的 gsid 对上了**
- `oauth2.0/m_me`
- `source=7501641714&room_id=`
- 候选 appkey / source：`1682569965`(42)、`6400657304`(35)、`7501641714`(18)、`4265682188`(10)
- 签名相关符号：`getUnifiedSign`、`ISign`、`SignatureVerify`、`ISecureSignatureComponent`

## 4. 类名发现绕行方案

`search_android_classes` 挂掉时，用 dex 字符串 + 本地 jadx：

```bash
# 类名清单（dex 字符串里含 com/sina/weibo/... 形式）
unzip -o -q weibo_official.apk 'classes*.dex' -d /tmp/weibo-dex
strings -n 10 /tmp/weibo-dex/classes*.dex > /tmp/weibo-strings.txt
grep -oE "com/sina/weibo/[a-z]+/[A-Za-z0-9_\$]{3,30}" /tmp/weibo-strings.txt | sort -u

# 单类反编译（走 REA）
rea inspect-android-class <apk> com.sina.weibo.WeiboApplication --format json
rea inspect-android-method <apk> <class> <method> --format json
rea trace-android-references <apk> <class> --format json
```

## 5. 登录链路（2026-10-13 深挖）

### 端点（`com.sina.weibo.net.i`）

| 端点 | 方法 |
|---|---|
| `/2/account/login` | `i.a(requestmodels.ib)` → `User` |
| `/2/guest/login` | `i.a(requestmodels.ic)` |
| `/2/account/login/confirm` | GET |
| `/2/account/login_sendcode` / `login_sendcall` / `login_smsverify` | |
| `/2/qtcode/login`、`/2/teenager/login` | |
| `/2/account/password_byphone` / `password_sendcode` / `password_update` | 改密 |

调用链：`LoginPresenter` → `requestmodels.*` → `net.i` → **base = `bm.cd`**
= `com.sina.weibo.uploadkit.upload.UploadParam.DEFAULT_HOST` = **`https://api.weibo.cn`**
→ `net.l` → `net.m`（真实 HTTP 引擎）

### 参数

`com.sina.weibo.models.IPlatformParam`：`c`(client)、`from`、`gsid`、`ua`、`wm`、`coordinate`、`offset`

### ⛔ 签名（核心卡点）

```java
// com.sina.weibo.net.i
bundle.putString("s", j(StaticInfo.e()));          // j() → com.sina.weibo.utils.js.a(String)

// com.sina.weibo.utils.js
public static String a(String str) {
    ... return com.sina.weibo.security.SLib.getInstance().newCalculateS(str, 3);
}

// com.sina.weibo.security.SLib
private native String nativeNewCalculateS(Context, String, int);
static { LoadLibraryLancet.loadLibraryReplace("slib"); }
```

`libslib.so`（413 KB）实测：
- 是**加壳库**：含 `ZipArchive`/`ExtractToMemory`/`is_unpack_success`/`get_unpack_result`
- 引用 `libsoshell.so`（再一层壳）、`libziparchive-private.so`
- 含 `NewCalc`、`SLibO(...)` JNI 签名；`JNI_OnLoad` 动态注册
- **真实算法在运行时解包后才存在** → dex/静态 so 都看不到

### 第二层：阿里 SecurityGuard（mtop 链路）

`mtopsdk.security.OpenSignImpl`：
- `getUnifiedSign()` → `IUnifiedSecurityComponent.getSecurityFactors()` → `x-sign`/`wua`/`x-sgext`/`x-umt`/`x-mini-wua`
- `convertOpenBaseStrMap()` 拼接 INPUT：`api&v&md5(data)&appkey&utdid&...`（**已可读**）
- 哈希：`SecurityUtils.getMd5` = MD5-UTF8 小写 hex（**已可读**）
- 但最终 `signRequest`/`getSecurityFactors` → **native（阿里安全保镖）**
- 硬编码线索：`"mainAppKey":"0DOU0K0WD05SLYU3"`

### 结论

**接口层可见（端点/参数/调用链完整），但 `s` 签名在 native 加壳库里，静态拿不到。**
要复刻 App 私有登录，必须：
1. 上原生逆向引擎（Hopper / Ghidra / IDA）
2. 逆 `libslib.so`（先脱壳）拿 `s` 算法 + 密钥
3. 逆向阿里 SecurityGuard so（若走 mtop 链路）
4. **动态验证**（frida hook `libslib` 导出 + mitmproxy 抓包比对）最省力

替代：用官方客户端自身签（frida 调用 `newCalculateS`）—— 但需真机/模拟器 + root/frida。

## 6. 实测：登录请求探针（2026-10-13）

对 `POST https://api.weibo.cn/2/account/login` 发了 2 次编造凭据的请求。

参数集（共 16 项，取自源码）：
`getcookie=1 getuser=1 getoauth=0 flag=1 u=<编造> p=<RSA(编造)> s=? c=android
 from=10G6195010 wm=3333_1001 v_p=93 android_id=… entity_type=3 networktype=wifi
 appkey=7501641714 ua=…`

| 变体 | HTTP | 响应 |
|---|---|---|
| 带**伪造** `s`（32 hex） | 200 | `{"errno":-105,"errtype":"DEFAULT_ERROR","errmsg":"客户端身份校验失败","isblock":false}` |
| **不带** `s` | 200 | 同样 `-105 客户端身份校验失败` |

### 结论

1. ✅ **数据结构基本正确** —— 两种情况下服务端都**没有报"缺少参数"**，说明 16 项参数形态被接受。
2. ❗ **`-105` 是前置闸门** —— 出现在业务校验（账号/密码）之前；
   去掉 `s` 错误不变，说明它是**整体客户端身份校验**，不只 `s` 一项
   （还可能涉及 appkey / 设备指纹 / 请求头等）。
3. ⚠️ **副作用**：由于卡在 -105，**无法验证 RSA 密码加密是否正确**（账号密码分支根本没被走到）。
4. 说明 `-105` 无法通过"删参数"绕开 —— 必须提供**合法客户端身份**。

### 对模块的影响

`Signer` 接口不仅需要补 `s`，很可能还需补一整套客户端身份
（设备指纹 `mfp`/`checktoken`、可能的专用请求头）。
建议下一步直接在真机/模拟器上用官方 App 抓一次真实登录请求，
逐字段对比后补齐。

## 7. 路线判定（2026-10-13 结论）

### 私有 API 登录：设计上不可行

1. `-105` 与**客户端身份（含 APK 签名/设备指纹）绑定** —— 实测：请求结构正确、只缺身份，一律 -105。
2. 绕过它只有两条路，**都要求 root**：
   - frida 注入（hook `SLib.newCalculateS`）
   - 装系统级 CA 证书抓包（Android 15 默认不信任用户 CA）
3. root 会被检测（SecurityGuard / `libdexvmp` / `libshadowhook`）。
   即使 Magisk+Zygisk+DenyList 藏住 root，还要再藏 frida，且最后得到的 `s` 仍绑死在那一个账号/设备上。
4. 与 caij.see 当年卡死的是**同一道墙**（debug 签名被检测）。

**结论：用官方私有 API 做第三方客户端登录 = 平台设计上不开放，放弃。**

### 可行替代：H5 / 网页 API

- 端点：`m.weibo.cn/api/...`（已有 61 个）、`passport.weibo.cn/signin`（SSO）
- 认证：SUB cookie（不靠 `s`，不靠客户端身份签到）
- 不需要：root / frida / 绕 -105
- 代价：能力窄于私有 API（无 App 专属接口）、有频控风控

### 本阶段产出（不因放弃而作废）

- 完整登录业务流程（分支/参数/端点）
- RSA 密码加密：公钥 + 算法，JVM 实测可加密
- `weibo-login-kt/` 模块骨架（`Signer` 接口保留）
- 工具链：REA + JADX + Ghidra 已就绪

## 8. 下一步候选

1. 用 REA 逐个反编译 `com.sina.weibo.netcore` / `accountsmanager` / `account` 包
2. 探 `network_security_config`：是否 certificate pinning（决定动态抓包可行性）
3. Flutter 半边：需 blutter 之类工具，REA 不覆盖
4. 动态验证：真机/模拟器 + mitmproxy 抓 `api.weibo.cn/2/*`，比对签名参数
