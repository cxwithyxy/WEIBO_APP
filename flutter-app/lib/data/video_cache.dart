import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

/// 视频文件缓存：`files/video/<mid>.mp4`。
///
/// 关键设计：
///  - **按 mid 命名，不按 URL** —— 微博直链带签名、约 1 小时就轮换，
///    用 URL 当键会造成「同一视频缓存无数份」且永远命中不了。
///  - 下载先写 `<mid>.mp4.part`，校验通过后 `rename` 成 `.mp4`：
///    进程被杀不会留下一个「看起来能播、其实只写了一半」的坏缓存。
///  - 首页/关注流里是**过期 URL**，播放器会先用 `statusDetail(mid)` 换新链接
///    再调这里下载（见 `VideoPlayerPage`）。
class VideoCache {
  VideoCache._();

  /// 缓存上限：500MB **或** 50 个文件，先到先淘汰（按 mtime LRU）。
  static const int maxBytes = 500 * 1024 * 1024;
  static const int maxFiles = 50;

  static const String _partSuffix = '.part';

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; MuMu) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/video');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// mid → 安全文件名（mid 正常是纯数字，这里只是防御性处理）。
  /// 目录路径（不创建）。给「设置页显示占用」用 —— 目录不存在就是 0。
  static Future<Directory> directory() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/video');
  }

  /// 当前占用：成品 `.mp4` 的字节数与文件数。
  ///
  /// IO 放到 isolate 里跑（`Isolate.run`），不占 UI 线程；
  /// 单个文件 stat 失败只跳过它，不整体失败。
  static Future<VideoCacheUsage> usage() async {
    final path = (await directory()).path;
    return Isolate.run(() => _usageSync(path));
  }

  /// 只清 `files/video/` 下的缓存文件（含 1 小时内没收掉的 `.part` 残留），
  /// **不碰** `feed/`、`status/`、cookies、封面图缓存。
  ///
  /// 删除同样在 isolate 里做。删不掉的（例如正在被播放器占用的文件）跳过并计数，
  /// 不让整次清空失败 —— 也不去碰播放器本身。
  static Future<VideoCacheClearResult> clear() async {
    final path = (await directory()).path;
    return Isolate.run(() => _clearSync(path));
  }

  static VideoCacheUsage _usageSync(String dirPath) {
    var bytes = 0;
    var files = 0;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return const VideoCacheUsage(0, 0);
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.isEmpty ? e.path : e.uri.pathSegments.last;
        if (!name.endsWith('.mp4') && !name.endsWith(_partSuffix)) continue;
        try {
          final st = e.statSync();
          if (st.type != FileSystemEntityType.file || st.size <= 0) continue;
          bytes += st.size;
          files++;
        } catch (_) {
          // 读不到的文件不算数
        }
      }
    } catch (_) {}
    return VideoCacheUsage(bytes, files);
  }

  static VideoCacheClearResult _clearSync(String dirPath) {
    var freed = 0;
    var deleted = 0;
    var failed = 0;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return const VideoCacheClearResult(0, 0, 0);
      for (final e in dir.listSync(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.isEmpty ? e.path : e.uri.pathSegments.last;
        if (!name.endsWith('.mp4') && !name.endsWith(_partSuffix)) continue;
        var size = 0;
        try {
          size = e.statSync().size;
        } catch (_) {}
        try {
          e.deleteSync();
          freed += size;
          deleted++;
        } catch (_) {
          // 被播放器占用 / 权限问题：跳过，剩余占用由调用方重新统计
          failed++;
        }
      }
    } catch (_) {}
    return VideoCacheClearResult(freed, deleted, failed);
  }

  static String fileNameFor(String mid) {
    final safe = mid.replaceAll(RegExp(r'[^0-9A-Za-z_-]'), '_');
    return '${safe.isEmpty ? 'unknown' : safe}.mp4';
  }

  static Future<File> fileFor(String mid) async =>
      File('${(await _dir()).path}/${fileNameFor(mid)}');

  /// 命中返回本地文件（并刷新 mtime，作为 LRU 的「最近使用」）。
  /// 文件不存在 / 空文件 / 读不到 → null。
  static Future<File?> lookup(String mid) async {
    if (mid.isEmpty) return null;
    try {
      final f = await fileFor(mid);
      final st = await f.stat();
      if (st.type != FileSystemEntityType.file || st.size <= 0) return null;
      // 刷新 mtime：下次淘汰时这条算「最近用过」。
      try {
        await f.setLastModified(DateTime.now());
      } catch (_) {}
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 下载 [url] 到 `<mid>.mp4`。
  ///
  /// - 只接受 HTTP 200/206；
  /// - Content-Type 明显是网页/JSON 时拒绝（防止把错误页当视频存下来）；
  /// - [onProgress] 持续回报已下载字节数 / 总字节数（服务端没给长度则为 null）；
  /// - [isCancelled] 返回 true 时立刻中止并删掉 `.part`。
  ///
  /// 失败会抛异常（调用方负责回退到在线播放）。
  static Future<File> download({
    required String mid,
    required String url,
    void Function(int received, int? total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (mid.isEmpty) {
      throw const VideoCacheException('缺少微博 mid，无法按条缓存');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      throw const VideoCacheException('视频地址无效');
    }

    final target = await fileFor(mid);
    final part = File('${target.path}$_partSuffix');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;

    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, _ua);
      req.headers.set(HttpHeaders.refererHeader, 'https://m.weibo.cn/');
      req.headers.set(HttpHeaders.acceptHeader, '*/*');
      final resp = await req.close();

      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        await resp.drain<void>().catchError((_) {});
        throw VideoCacheException('HTTP ${resp.statusCode}');
      }

      final mime = (resp.headers.contentType?.mimeType ?? '').toLowerCase();
      // 只挡明显的错误页；CDN 有时给 application/octet-stream，不能一刀切。
      if (mime.contains('text/') ||
          mime.contains('json') ||
          mime.contains('html') ||
          mime.contains('xml')) {
        await resp.drain<void>().catchError((_) {});
        throw VideoCacheException('返回的不是视频（Content-Type: $mime）');
      }

      final total = resp.contentLength > 0 ? resp.contentLength : null;
      if (total == 0) {
        throw const VideoCacheException('视频长度是 0');
      }

      if (await part.exists()) await part.delete();
      sink = part.openWrite();
      var received = 0;

      await for (final chunk in resp.timeout(const Duration(seconds: 30))) {
        if (isCancelled?.call() ?? false) {
          throw const VideoCacheCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received <= 0) {
        throw const VideoCacheException('下载到 0 字节');
      }
      if (total != null && received < total) {
        throw VideoCacheException('下载不完整（$received/$total 字节）');
      }

      // 已有同名成品（并发/上一次没删干净）→ 先删再 rename。
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
      await _evict(excludePath: target.path);
      return target;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      if (e is VideoCacheException || e is VideoCacheCancelled) rethrow;
      throw VideoCacheException(e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// LRU 淘汰：超过 500MB 或 50 个文件就按 mtime 从旧到新删。
  /// 同时清掉超过 1 小时的 `.part` 残留。
  static Future<void> _evict({String? excludePath}) async {
    try {
      final dir = await _dir();
      final now = DateTime.now();
      final all = <_CacheEntry>[];

      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.isEmpty
            ? e.path
            : e.uri.pathSegments.last;
        try {
          final st = await e.stat();
          if (name.endsWith(_partSuffix)) {
            if (now.difference(st.modified) > const Duration(hours: 1)) {
              await e.delete();
            }
            continue;
          }
          if (!name.endsWith('.mp4')) continue;
          all.add(_CacheEntry(e.path, st.size, st.modified));
        } catch (_) {
          // 单个文件读不到不影响其它文件
        }
      }

      var total = all.fold<int>(0, (s, e) => s + e.size);
      var count = all.length;
      all.sort((a, b) => a.modified.compareTo(b.modified));

      for (final e in all) {
        if (total <= maxBytes && count <= maxFiles) break;
        if (e.path == excludePath) continue;
        try {
          await File(e.path).delete();
          total -= e.size;
          count--;
        } catch (_) {}
      }
    } catch (_) {
      // 淘汰失败不影响播放
    }
  }
}

/// 视频缓存当前占用（`VideoCache.usage()` 的返回值）。
class VideoCacheUsage {
  const VideoCacheUsage(this.bytes, this.files);

  final int bytes;
  final int files;

  bool get isEmpty => files == 0;

  /// `28.5 MB · 2 个文件`；空则是 `0 B`。
  String get label => isEmpty ? '0 B' : '${formatCacheBytes(bytes)} · $files 个文件';
}

/// 一次清空的结果。
class VideoCacheClearResult {
  const VideoCacheClearResult(this.freedBytes, this.deleted, this.failed);

  final int freedBytes;
  final int deleted;

  /// 删不掉（多为正被播放的文件）的数量
  final int failed;
}

/// 字节数 → 人读格式：`0 B` / `812 KB` / `28.5 MB` / `1.2 GB`。
///
/// 用 1024 进制但标 KB/MB/GB（与系统「应用信息」里的口径一致）；
/// 1 KB 以下保留整数字节，其余保留 1 位小数。
String formatCacheBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  if (u == 0) return '$bytes B';
  return '${v.toStringAsFixed(1)} ${units[u]}';
}

class _CacheEntry {
  _CacheEntry(this.path, this.size, this.modified);

  final String path;
  final int size;
  final DateTime modified;
}

class VideoCacheException implements Exception {
  const VideoCacheException(this.message);

  final String message;

  @override
  String toString() => message;
}

class VideoCacheCancelled implements Exception {
  const VideoCacheCancelled();

  @override
  String toString() => '下载已取消';
}
