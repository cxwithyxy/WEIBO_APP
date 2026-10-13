# 微博 Web API 接口清单（自研客户端用）

> 2026-10-13 实测　会话来源：扫码登录（`/sso/v2/qrcode/*`）拿到的 `.weibo.com` cookie（SUB/SUBP/ALF/ALC/SCF）
> 已封装为可运行库：`~/weibo-client-kt/`（命令 `whoami / hot / band / timeline / meblog / user / detail / comments / reposts / search`）

## 认证方式

```
1. GET  https://passport.weibo.com/sso/signin?entry=wapsso&source=wapssowb   → 下发 X-CSRF-TOKEN
2. GET  https://passport.weibo.com/sso/v2/qrcode/image?entry=wapsso&size=300 → qrid + 二维码图URL
3. 手机微博 App 扫码 → 确认
4. GET  https://passport.weibo.com/sso/v2/qrcode/check?...qrid=...          → 拿到跳转 URL
5. 跟随跳转链 → 得到 cookie：SUB / SUBP / ALF / ALC / SCF（域 .weibo.com，约 30 天）
```

**请求头要求**：桌面 UA、`Referer: https://weibo.com/`（登录后 `/u/<uid>`）、`X-Requested-With: XMLHttpRequest`

⚠️ **`Referer` 缺失 → `403 {"error":"Forbidden"}`**（硬性校验）

取自己 uid：`GET https://weibo.com/` → HTML 里的 `"uid":<数字>`

## ✅ 实测可用（读接口，全部本轮复验）

| 功能 | 接口 | 数据路径 |
|---|---|---|
| 热搜榜（简） | `GET /ajax/side/hotSearch` （公开，无需登录） | `data.realtime` |
| 热搜榜（详） | `GET /ajax/statuses/hot_band?band_id=1&count=50` | `data.band_list`（word/note/num/label_name/realpos） |
| 我的资料 | `GET /ajax/profile/info?uid=<uid>` | `data.user` |
| 个人详情 | `GET /ajax/profile/detail?uid=<uid>` | `data`（职业/公司/教育/生日/阳光信用） |
| 微博列表 | `GET /ajax/statuses/mymblog?uid=<uid>&page=1&feature=0` | `data.list`（本人/他人通用） |
| **首页时间线** | `GET /ajax/feed/unreadfriendstimeline?since_id=0&refresh=1&count=20` | `statuses` |
| 关注列表 | `GET /ajax/profile/followContent?uid=<uid>` | `data.follows.users` |
| **单条详情** | `GET /ajax/statuses/show?id=<mid>` | **直接是微博对象（无 ok 信封！）** |
| **评论** | `GET /ajax/statuses/buildComments?is_reload=1&id=<mid>&is_show_bulletin=2&is_mix=0&count=20&max_id=0&flow=0` | `data[]`、`total_number`、`max_id`（`count` 被忽略；翻页只能 flow=1） |
| **转发** | `GET /ajax/statuses/repostTimeline?id=<mid>&page=1` | `data[]`、`total_number` |
| **搜索微博** | `GET /ajax/statuses/search?q=<关键词>&count=20&page=1` | `statuses[]`、`total_number` |
| 搜索联想词 | `GET /ajax/side/search?q=<关键词>` | `data.hotquery[]` |

### 关键坑位

| 现象 | 原因 / 处理 |
|---|---|
| `statuses/show` 无 `ok` 字段 | 正常，直接反序列化为微博对象，**不要套 ok 检查** |
| 评论 `count` 被忽略 | 服务端固定返回 20 条 |
| 评论**按热度（flow=0）翻不了页** | 传回 `max_id` 拿不到第二页（max_id_type 0/1/2 均无效）；`page` 也无效 → **要完整列表请用 `flow=1`（按时间）** |
| 评论按时间（flow=1）翻页 | ✅ 用响应 `max_id` 传回即可 |
| 搜索结果翻页 | 无 `since_id`/`max_id`，用 `page`（已验证有效） |
| 转发翻页 | `page` 有效，响应带 `total_number`/`max_page`/`next_cursor` |
| `mymblog` 空账号 | 返回 `ok:1` + 空 `list`，不是错误 |
| `403 {"error":"Forbidden"}` | 缺 `Referer` |

## ❌ 实测不可用

| 接口 | 返回 |
|---|---|
| `/ajax/statuses/likeTimeline` | 你访问的地址不存在 |
| `/ajax/search/all` · `/ajax/search/statuses` | 你访问的地址不存在 |
| `/ajax/profile/getFriendList` | 你访问的地址不存在 |
| `/ajax/feed/group` | `ok=0`（分组列表） |
| `/ajax/remind/unread_count` | `ok=0`（未读数） |

> 注：`https://s.weibo.com/weibo?q=<关键词>` 也会返回 HTML 搜索结果页（可用但解析麻烦，优先用 `/ajax/statuses/search`）。

## 待补测

- 话题 / 超话详情（`/ajax/statuses/show?id=<topic mid>` 可部分替代）
- 用户搜索（微博搜索可用，用户搜索接口未找到）
- 关注 / 取关
- 写操作：发博 / 转发 / 点赞 / 评论（**风控更敏感，需节流 + 拟人化**）

## 能力边界（对比官方 App）

| 能力 | Web API | 说明 |
|---|---|---|
| 时间线 / 资料 / 关注 / 热搜 | ✅ | 已验证 |
| 详情 / 评论 / 转发 / 搜索 | ✅ | 已验证 |
| 发博 / 点赞 / 评论 | 大概率可以 | 但风控敏感，需节流 |
| 私信 | 可能性低 | |
| 实时推送 | ❌ | 只能轮询 |
| 视频上传 / 直播 | ❌ | App 专属 |

## ⚠️ 工程风险

1. **接口无契约**：私人 Web API，微博前端一更新就可能挂 → 已做接口层隔离（`WeiboClient.kt`），便于修补
2. **风控**：Web 端对自动化更敏感；写操作尤其要节流 + 拟人化
3. **Cookie 30 天过期**：需重新扫码登录 → 设计成"失效时提示重登"
4. **JDK HttpClient 陷阱**：`CookieManager` 外部注入的 cookie 不外发、且丢失跨跳转 `Set-Cookie` → 必须自管 cookie
5. **合规**：仅自用/学习；公开发布违反平台协议
