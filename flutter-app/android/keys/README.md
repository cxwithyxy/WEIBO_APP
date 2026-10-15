# 构建签名 key（**故意公开**）

> ⚠️ 看到"keystore 被提交进仓库"先别急着当成事故 —— 这是**有意为之**。

## 为什么要公开

本项目是**自用 / 学习 / 互操作研究**用途，不上架任何应用商店。核心诉求是：

> 任何人 clone 下来自己编译，编出来的 APK 和官方 Release **签名一致**，
> 于是可以互相覆盖安装（不用先卸载、不会丢数据、不会报 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

要做到这一点，签名 key 就必须是**公开且固定的** —— 藏在 GitHub Secrets 里只能保证
CI 自己的产出一致，第三方自己编译仍然签不上同一个名。

## 代价（想清楚再用）

- 任何人都能用这个身份签 APK 并冒充"官方更新"分发。
- 因此这套 key **永远不要**用于上架商店、或任何需要真实身份的场景。
- 想自己出一版独立的，删掉 `key.properties` 即可退回 debug 签名。

## 内容

| 项 | 值 |
|---|---|
| 文件 | `flutter-app/android/keys/weibo-release.jks` |
| 配置 | `flutter-app/android/key.properties` |
| 别名 | `weibo` |
| 库口令 | `weibo-release` |
| 密钥口令 | `weibo-release` |
| 算法 / 位数 | RSA 2048 |
| 有效期 | 10950 天（≈30 年） |
| 证书 SHA-256 | `F6:98:B7:13:67:4E:5D:90:70:FF:FA:8F:FD:DA:38:21:2F:24:F2:A5:BC:40:D8:8D:17:FC:3E:A4:DD:46:BE:A4` |

## 校验签名（确认你的构建签对名了）

```bash
apksigner verify --print-certs app-release.apk
# Signer #1 certificate SHA-256 digest:
#   f698b713674e5d9070fffa8ffdda38212f24f2a5bc40d88d17fc3ea4dd46bea4
```

与上表的 SHA-256 一致 → 你的包能覆盖安装官方 Release。

## 怎么用

不用做任何事 —— `flutter-app/android/key.properties` 会自动被 `app/build.gradle.kts` 读取。
`key.properties` 缺失时退回 debug 签名（仍然能构建，只是签名不一致）。
