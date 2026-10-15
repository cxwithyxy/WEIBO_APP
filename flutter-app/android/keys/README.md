# 构建签名 key（**故意公开**）

> ⚠️ 看到"keystore 被提交进仓库"先别急着当成事故 —— 这是**有意为之**。

## 为什么要公开

本项目是**自用 / 学习 / 互操作研究**用途，不上架任何应用商店。核心诉求是：

> 任何人 clone 下来自己编译，编出来的 APK 和官方 Release **签名一致**，
> 于是可以互相覆盖安装（不用先卸载、不会丢数据、不会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

要做到这一点，签名 key 就必须是**公开且固定的** —— 藏在 GitHub Secrets 里只能保证
CI 自己的产出一致，第三方自己编译仍然签不上同一个名。

## 为什么是「Android 默认调试 key」而不是新生成一把

这把 key 就是本机 `~/.android/debug.keystore`（别名 `androiddebugkey`，口令 `android`）。
**原样**公开它，而不是另生成一把，原因很实际：

- **已经装过 App 的设备，签名就是这把 key** —— 继续用它才能**原地覆盖升级**；
- 生成新 key 会强制所有人（包括自己）**卸载重装一次**，而卸载会清掉登录态。

也就是说：选这把 key 是刻意的，目的是**零迁移成本**。

## 代价（想清楚再用）

- 任何人都能用这个身份签 APK 并冒充"官方更新"分发。
- 因此它**永远不要**用于上架商店、或任何需要真实身份的场景。
- 如果本机还有**其它**用同一把 debug key 调试过的项目，那它们的调试包也共享这个签名身份
  —— 本仓库公开它等于公开了那部分身份。本项目自用场景下接受这一点。
- 想签自己的名：删掉 `flutter-app/android/key.properties` 即可退回各自的 debug 签名。

## 内容

| 项 | 值 |
|---|---|
| 文件 | `flutter-app/android/keys/debug.keystore` |
| 配置 | `flutter-app/android/key.properties` |
| 别名 | `androiddebugkey` |
| 库口令 | `android` |
| 密钥口令 | `android` |
| 证书 SHA-256 | `c5e27bffb47bce52d2632b467361f99ccac9893cc5e4750d0f28e586d0d41334` |
| DN | `C=US, O=Android, CN=Android Debug` |

## 校验签名（确认你的构建签对名了）

```bash
apksigner verify --print-certs app-release.apk
# Signer #1 certificate SHA-256 digest:
#   c5e27bffb47bce52d2632b467361f99ccac9893cc5e4750d0f28e586d0d41334
```

与上表的 SHA-256 一致 → 你的包能覆盖安装官方 Release。

## 怎么用

不用做任何事 —— `flutter-app/android/key.properties` 会自动被 `app/build.gradle.kts` 读取。
`keys/debug.keystore` 缺失时退回本机 debug 签名（仍然能构建，只是签名不一致）。
