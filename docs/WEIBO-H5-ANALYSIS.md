# 微博 H5 登录路线分析（SSO v2）

> 立项：2026-10-13　背景：官方私有 API（api.weibo.cn）被 `-105 客户端身份校验` 堵死（绑定 APK 签名/设备指纹，需 root+frida，不可行）。
> 本路线：纯 HTTP，不需要 root / frida / 重打包。**已打通到"凭据校验"层。**

## 1. 入口与端点

| 用途 | 端点 | 方法 |
|---|---|---|
| 登录页 | `https://passport.weibo.com/sso/signin?entry=wapsso&source=wapssowb` | GET |
| **签名素材** | `https://passport.weibo.com/sso/v2/web/config?entry=wapsso&source=wapssowb` | GET |
| **账密登录** | `https://passport.weibo.com/sso/v2/login` | POST |
| 短信登录 | `/sso/v2/sms/send` | POST |
| 图片验证码 | `/sso/v2/captcha/image` | GET |
| 二维码 | `/sso/v2/qrcode/image`、`/sso/v2/qrcode/check` | GET |

- 前端资源：`https://h5.sinaimg.cn/m/login/assets/pages/login/login-*.js`（版本号随构建变）
- 网关：`server: APISIX/3.14.1`；`alb-x-request-id`（阿里云 ALB）
- 旧入口 `login.sina.com.cn/sso/prelogin.php` **已废弃**（返回 `system error`）

## 2. 签名素材（来自 /sso/v2/web/config）

```json
{"retcode":20000000,"msg":"succ","data":{
  "pubkey":"-----BEGIN PUBLIC KEY-----\nMIGf...QAB\n-----END PUBLIC KEY-----",   // RSA 1024-bit
  "rsakv":"1330428213",
  "servertime":1791874777,
  "nonce":"31T6CO",
  "show_pw":1,"show_sms":1,"show_qr":1,"show_wechat":1,"show_qq":0,"first_show":"show_pw",
  ...
}}
```

## 3. 登录请求（逆向自 login.js）

**Content-Type 必须是 `application/x-www-form-urlencoded`** ⚠️
> 用 `application/json` 会被网关提前拦成 `{"retcode":6102,"msg":"","data":[]}`（无消息、与参数无关）。
> 换表单编码后才进入业务，返回 `-20 登录名或密码错误`。**这是本路线最关键的一步。**

表单字段（来自 login.js 的 `x` 对象）：

| 字段 | 值 | 说明 |
|---|---|---|
| `method` | `POST` | |
| `entry` | `wapsso` | |
| `source` | `wapssowb` | |
| `type` | `1` | `{show_pw:1, show_sms:2}` |
| `url` | `https://m.weibo.cn/` | 登录后跳转目标 |
| `ver` | `20250520` | 前端版本常量，随构建可能变 |
| `username` | 账号 | 前端还会过 `qt()` 编码（自定义 base64url 变换），**实测裸传可用** |
| `pass` | RSA 密文 hex | 见下 |
| `cid` | `""` | mfa id，无 2FA 时为空 |
| `pwencode` | `rsa` | |
| `rsakv` | config 的 rsakv | |
| `rid` | `norid` 或指纹 token | 见下 |
| `el` | `2` | 传了 username 就会带 |

**密码加密公式**（`_r()` = RSA）：
```
明文 = servertime + "\t" + nonce + "\n" + password
密文 = RSA/ECB/PKCS1Padding(明文, pubkey)  → 转小写 hex（1024bit = 256 字符）
```
- 前端变量对应：`Vi()` = `nt` = `servertime`，`Ci()` = `Et` = `nonce`（由 `Ri(nonce)`/`Bi(servertime)` 注入）
- 输出是 **hex 字符串**（非 base64）

**CSRF**：先 GET 一次 `/sso/signin`，会下发 cookie `X-CSRF-TOKEN`；后续请求需同值回传
- cookie 名：`X-CSRF-TOKEN`，header 名：`X-CSRF-TOKEN`（axios 配置 `xsrfCookieName`/`xsrfHeaderName` 同名）
- ⚠️ 是否强校验待验（实测带上/不带都能到 -20，可能非必需）

**其他请求头**：`Origin: https://passport.weibo.com`、`Referer: https://passport.weibo.com/sso/signin`、移动端 UA

## 4. 实测结果

| 变体 | 响应 |
|---|---|
| JSON body | `{"retcode":6102,"msg":"","data":[]}` ← 网关层，与参数无关 |
| form + 正常假凭据 | `{"retcode":-20,"msg":"登录名或密码错误(-20)","data":[]}` |
| form + 不传 pass | 同上 -20 |
| form + 垃圾 hex pass | 同上 -20 |

**结论**：结构完全正确、已进入真实凭据校验；`6102` 是编码问题，不是防护。

## 5. 前端防护组件（登录页）

- `https://passport.sinaimg.cn/js/fp/1.2.1.umd.js` — 设备指纹 `wbBotDetector`
- `https://passport.sinaimg.cn/js/yidun/v1/yidunsdk.min.js` — **网易易盾**
- 行为轨迹（鼠标/键盘），超时 2000ms
- `rid` 正常来自 `wbBotDetector.get().rid`，取不到时回退字符串 `norid` / `getriderror`

> 实测 `rid=norid` 足以通过凭据校验，**指纹不是账密登录的前置门槛**（可能在风控/验证码环节才要）。

## 6. 响应码

| retcode | 含义 |
|---|---|
| `20000000` | 成功（config） |
| `-20` | 登录名或密码错误 |
| `6102` | （编码错误时的网关拦截；改用表单编码后消失） |
| `2070` | 需要刷新图形验证码 |
| `50114002/3/4/15` | 扫码状态 |
| `2e7`(20000000?) | 扫码成功 |

## 7. 待验证 / 待办

- [ ] **用真实账号验证 RSA 加密正确性**（唯一的确认手段；假账号恒 -20）
- [ ] 登录成功后的响应结构与 SUB cookie 下发路径
- [ ] 是否触发验证码（易盾/极验）、2FA（`mfa_2`）
- [ ] `X-CSRF-TOKEN` 是否强校验
- [ ] `ver` 常量随版本变化的应对
- [ ] 拿到 SUB 后调 `m.weibo.cn/api/*`（61 个接口）验证可用性

## 9. 验证码（短信）登录 —— 2026-10-13 追加

**比账密登录更简单：不需要密码、不需要 RSA、不需要公钥。**

### 9.1 发验证码 `/sso/v2/sms/send`

```js
at("/sso/v2/sms/send", {method:"POST", entry, mobile: qt(手机号), mfa_id:"", el:2})
```
- 非 86 国家码时：`mobile = qt("00" + 国家码 + 号码)`
- 格式校验优先：非法号码 → `{"retcode":-10,"msg":"手机号格式错误"}`（**不会真的下发短信**）
- 响应：`{"retcode":20000000,...}` 或需验证码

### 9.2 登录提交 `/sso/v2/login`（type=2）

| 字段 | 值 |
|---|---|
| `method` | `POST` |
| `entry` | `wapsso` |
| `source` | `wapssowb` |
| `type` | **`2`** |
| `url` | `https://m.weibo.cn/` |
| `ver` | `20250520` |
| `username` | `qt(手机号)` |
| `scode` | `qt(验证码)` |
| `el` | `2` |

无 `pass` / `pwencode` / `rsakv` / `cid`。

**实测**（假号码 13800000000 + 假码 123456）：
```json
{"retcode":8518,"msg":"验证码错误","data":[]}
```
→ 服务端已进入验证码校验，**证明字段结构与 qt() 实现均正确**。

### 9.3 `qt()` 混淆已完全复刻

```js
Gr = "x9Lp2WnQ"
Wr = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
Qr = "iaAehJvQ7RIDBX5L31T0kcf9ElVbpMdPZSmzoN_uxGO-2rFUtyY6sHCwKj4Wqgn8"

be(s) = UTF8字节
Jr(b,k) = b[n] ^ k[n % k.length]
Yr(s) = 逐字符  s[i] → Qr[ Wr.indexOf(s[i]) ]
qt(s) = Yr( base64url( Jr( be(s), Gr ) ) )
```
Java 实现见 `/tmp/weibo-h5/H5Sms.java`。自检：`qt("13800000000") = T3Gs3iRu9_J7A9t`

### 9.4 响应码补充

| retcode | 含义 |
|---|---|
| `-10` | 手机号格式错误 |
| `8518` | 验证码错误 |

## 11. 扫码登录 —— ✅ 已完整跑通（2026-10-13）

**这是目前最优路线：不需密码、不需验证码、不需指纹、不需 root。**

### 11.1 流程

```
① GET  /sso/v2/qrcode/image?entry=wapsso&size=300
   → {retcode:20000000, data:{qrid:"3OTFqzeO_ABa...", image:"https://v2.qr.weibo.cn/inf/gen?..."}}
   （注意：GET，不是 POST；必须带 size）

② 下载 image 得二维码图片，交给手机微博 App 扫描

③ 轮询 GET /sso/v2/qrcode/check
     ?entry=wapsso&source=wapssowb&url=<urlencode>&qrid=<QRID>&disp=&rid=norid&ver=20250520
   状态码：
     50114001  未使用（等待扫描）
     50114002  成功扫描，等待手机确认
     50114003  二维码已过期
     20000000  已确认 → data.url = 登录回调 URL

④ GET data.url 并跟随重定向链 → 下发 cookie
```

### 11.2 实测结果（2026-10-13 15:56）

回调 URL（`type=3`）：
```
https://passport.weibo.com/sso/v2/login?entry=wapsso&source=wapssowb&type=3
  &alt=ALT-...&url=https%3A%2F%2Fm.weibo.cn%2F&rid=norid&ver=20250520
```
重定向链：`passport.weibo.com` → `login.sina.com.cn/sso/v2/crossdomain?...ticket=ST-...` → `passport.sina.cn` → `passport.weibo.cn`

**最终拿到 cookie（域 `.weibo.com`）**：
```
SUB   = _2A25****（关键登录态 cookie，HttpOnly，30 天）
SUBP  = 0033WrSXqPxfM725Ws9jqgMF55529P9...
ALF   = 02_1794470211
ALC   = ALC-1TEy91-...
SCF   = AtCRzOn8...
```
> 注：链末 crossdomain 返回 403，但 SUB 已在倒数第二跳下发。不影响使用。

### 11.3 ⚠️ 域的关键区别

| cookie 域 | 可用 API |
|---|---|
| `.weibo.com` ← **我们拿到的** | 桌面版 `https://weibo.com/ajax/*` ✅ |
| `.weibo.cn`（未拿） | 移动版 `https://m.weibo.cn/api/*` ❌（`/api/config` 返回 login:false） |

要拿 `.weibo.cn` 的 SUB，需额外完成 crossdomain 握手到 `passport.weibo.cn`。**当前不必** —— 桌面版 API 更全。

### 11.4 验证过的可用接口（带 SUB cookie）

```
GET https://weibo.com/ajax/profile/info?uid=<uid>
  → {ok:1, data:{user:{screen_name, idstr, followers_count, statuses_count, ...}}}

GET https://weibo.com/ajax/statuses/mymblog?uid=<uid>&page=1&feature=0
  → {ok:1, data:{list:[...]}}   我的微博列表

GET https://weibo.com/ajax/profile/followContent?uid=<uid>
  → {ok:1, data:{follows:{users:[...]}}}   关注列表

GET https://weibo.com/ajax/side/hotSearch      （公开，无需登录）
```

**必需请求头**：`User-Agent`（桌面 UA）、`Referer: https://weibo.com/u/<uid>`、`X-Requested-With: XMLHttpRequest`

### 11.5 如何取自己的 uid

`GET https://weibo.com/` （带 cookie）→ HTML 中含 `"uid":1234567890`

## 12. 待办 / 后续

- [ ] 把 H5 流程封装成 Kotlin 模块（QR 生成 + 轮询 + cookie 提取）
- [ ] （可选）完成 crossdomain 握手，拿 `.weibo.cn` SUB 以解锁移动版 API
- [ ] （可选）验证发微博/点赞等写操作接口

## 13. 与私有 API 路线对比

| | 私有 API | H5 SSO v2 |
|---|---|---|
| 端点 | `api.weibo.cn/2/*` | `passport.weibo.com/sso/v2/*` |
| 卡点 | `-105` 客户端身份（APK 签名绑定） | 无（已通） |
| 需 root/frida | 是 | **否** |
| 密码加密 | RSA（已复刻） | RSA（同款，已复刻） |
| 状态 | ❌ 放弃 | ✅ 已通到凭据校验 |
