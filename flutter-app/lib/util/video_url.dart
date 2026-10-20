/// 微博视频直链的「签名有效期」判断与下载量格式化。
///
/// 微博 CDN 直链形如：
/// `http://f.video.weibocdn.com/o0/xxx.mp4?label=mp4_720p&Expires=1761...&ssig=...`
///
/// `Expires` 是 **epoch 秒**。缓存的信息流里存的是几天前的响应原文，里面的
/// URL 早就过期了 → CDN 403 → 播放器报 `Source error`。所以播放前必须
/// 用本地文件缓存 / 重新拉详情换新链接（见 `VideoPlayerPage`）。
library;

final _expiresRe = RegExp(r'[?&]Expires=(\d+)', caseSensitive: false);

/// 解析 URL 里的 `Expires=` → 过期时间（UTC）。没有该参数返回 null。
DateTime? videoUrlExpiry(String url) {
  if (url.isEmpty) return null;

  int? epoch;
  final query = Uri.tryParse(url)?.queryParameters;
  if (query != null) {
    final raw = query['Expires'] ?? query['expires'];
    if (raw != null) epoch = int.tryParse(raw);
  }

  // Uri 解析失败 / 参数被奇怪编码时，退回原串正则。
  if (epoch == null) {
    final m = _expiresRe.firstMatch(url);
    if (m != null) epoch = int.tryParse(m.group(1)!);
  }

  if (epoch == null || epoch <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
}

/// URL 是否仍然可用：过期时间距现在还有 [margin] 以上。
///
/// 没有 `Expires=` 的 URL 视为「不透明、按可用处理」（不误伤非签名链接）。
/// [now] 仅供测试注入。
bool isVideoUrlFresh(
  String url, {
  DateTime? now,
  Duration margin = const Duration(seconds: 60),
}) {
  if (url.isEmpty) return false;
  final expiry = videoUrlExpiry(url);
  if (expiry == null) return true;
  final n = (now ?? DateTime.now()).toUtc();
  return expiry.isAfter(n.add(margin));
}

/// 字节数 → `12.3 MB` / `456 KB`（下载进度展示用）。
String formatBytes(int bytes) {
  if (bytes < 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
