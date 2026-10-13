# See微博（caij.see）逆向分析笔记

> 2026-10-13　工具：REA（Ghidra 12.1.4）+ JADX + aapt/apksigner
> 目标：能否分析 See微博 并修复其登录问题

## 1. 技术本质

See微博 是第三方客户端，走**微博私有 App API**（`api.weibo.cn/2/*`），不是官方开放平台。

关键类（`com.sina.weibo.*` 由 See微博 自带）：

```java
public class WeiboApplication {   // System.loadLibrary("utility")
    public native String newCalculateS(String str);      // ← s 签名
    public native String newCalculateSExt(String str);
    public native e getNetInstance(...);  public native void init(...);
}
```

- 登录接口（Retrofit）：`com.caij.see.Wwwwwwwwwwwwwwwwwx` → `@h22("/2/account/login")`
- 网络层：`com.sina.weibo.netcore.WeiboNetCore`（Java，可读）
- 构建：`new WeiboNetCore.Builder().gsid(...).uid(j).appkey(10000).wm("2468_1001").ua("weibo_netcore_1.1")`
- 账号持久化：Room `AccountV2`（uid / gsid / sut / screen_name / avatar / oauth）

## 2. 原生库

| 库 | 大小 | 作用 | 防护 |
|---|---|---|---|
| `libutility.so` | ~1MB | **`newCalculateS` 在这里** | `.datadiv_decode*` 字符串加密 + `JNI_OnLoad` 动态注册 + **控制流平坦化** + `"Parse signature failed"`（签名自检） |
| `libweibosdkcore.so` | 26KB | OAuth 签名 `calcOauthSignNative` | 无（但 **Java 侧无调用 → 死代码**） |
| `libdexinterpret.so` | 10KB | `NativeChecker.f/isSuccess` | 无 |

### 已完整还原的算法（libweibosdkcore.so，虽为死代码）

```
SALT   = "edafw2436ef8a3t4"            // 位于 0x10508a，16 字节
md5_1  = MD5(param4 + SALT + param5)
tmp    = md5_1[26:32] + md5_1[26:30]
md5_2  = MD5(tmp)
sign   = md5_1[26:32] + md5_2[31]      // 7 字符
```
`MDString` = 标准 MD5（初值 67452301/efcdab89/98badcfe/10325476），输出 32 位小写 hex。

## 3. 服务端闸门（实测 api.weibo.cn）

| 请求 | 返回 |
|---|---|
| `/2/account/login` 无 `s` | `-105 客户端身份校验失败` |
| `/2/users/show` 无 `s` | `-200 校验参数不存在` |
| `/2/users/show` 有 `s`（无 app 会话） | `-100 您的身份已失效，请重新登录` |
| `/2/statuses/hot_timeline` | 超时空响应 |

**结论**：`s` 是所有 `/2/` 接口必需的"校验参数"；带上后才校验**用户会话**（gsid/sut）。`-105` 是登录接口特有的**前置客户端身份闸门**。

## 4. ⚠️ 关键反转：原始签名就在手上

```
apk_variants/base.apk  =  原始 See微博（未改动）
  Signer DN     : CN=Caij
  SHA-256       : 66879dda6a58d815b1e5f3eb38b9159a9d114de566e1eff4271f597838e1f3fe
  SHA-1         : af986a14406769665320b75ce37c95b585a156ac
  签名文件       : META-INF/SEE.RSA / SEE.SF（原始，无 lspatch 痕迹）

base-639-npatched.apk（改签包）
  apksigner verify -v  →  DOES NOT VERIFY   ← 连合法签名都不是
```

**所以"需要 Caij 原始 keystore"这个结论方向错了** —— 需要的不是私钥，是**签名本身保持不变**。

## 5. 推荐修复路径：改用 root + LSPosed（不重打包）

| 方案 | APK 签名 | 自检 | 状态 |
|---|---|---|---|
| LSPatch/NPatch 重打包（现状） | ✗ 变了、且无效 | ✗ 失败 | 已卡死 |
| **root + LSPosed** | ✓ 保持 CN=Caij | ✓ 应直接通过 | **推荐** |
| hook 签名读取点喂原始签名 | ✓ | ? | 备选，libutility 若原生读文件则 Java hook 不够 |

- 原包**一个字节都不动** → 自检天然通过
- 模块运行时注入（与 SeePatch 相同逻辑，只换载体）
- MuMu 的 ROOT 开关是现成的
- ⚠️ Android 15（SDK 35）对 LSPosed 支持可能不佳 → 可改用 MuMu 的 Android 12/13 实例
- See微博 本身不检测 root（检测 root 的是**官方 App**）

## 6. 仍待解决 / 未验证

- [ ] 即使自检通过，仍需**有效 gsid/sut** 会话 → SeePatch 从同机官方微博注入（需官方 App 已登录）
- [ ] 我们 H5 路线拿到的是 **web SUB**，不是 gsid → 不能直接替代
- [ ] `libutility.so` 自检到底读 APK 文件还是 Java API（决定备选方案是否可行）
- [ ] 开 root 后实测自检是否真通过（理论上是）
