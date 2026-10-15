import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一个信息流缓存快照：**服务端响应原文**（一页一条）+ 下一页游标。
///
/// 两个设计点都是从原 Android 版 `FeedCache` 继承来的（原版为此踩过坑）：
///
///  1. **存原文，不存解析结果** —— 重开时用 core 的 `parseTimelineRaw` 解析，
///     走的是和网络路径**完全相同**的解析代码。这样 core 里改了字段/宽松度，
///     老缓存依然能被正确解析；存解析结果就会因为模型变化而失效。
///  2. **必须一起存游标** —— 只存正文不存游标，「加载更多」就断了。
class FeedSnapshot {
  const FeedSnapshot({required this.pages, this.cursor});

  /// 每次成功请求的响应原文（一页一条，按顺序）
  final List<String> pages;

  /// 下一页游标（首页流是 since_id，关注流是页码）
  final String? cursor;

  Map<String, Object?> toJson() => {'pages': pages, 'cursor': cursor};

  static FeedSnapshot fromJson(Map<String, Object?> m) => FeedSnapshot(
        pages: (m['pages'] as List?)?.cast<String>() ?? const [],
        cursor: m['cursor'] as String?,
      );
}

Future<Directory> _sub(String name) async {
  final base = await getApplicationSupportDirectory();
  final d = Directory('${base.path}/$name');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

/// 原子写：先写 `.tmp` 再 rename —— 写一半被杀进程也不会留下坏文件。
Future<void> _atomicWrite(File target, String content) async {
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(content);
  await tmp.rename(target.path);
}

/// 信息流缓存（按 feed 名分文件：`home` / `following` / `user_<uid>`）
class FeedCache {
  static Future<File> _file(String feed) async =>
      File('${(await _sub('feed')).path}/$feed.json');

  static Future<FeedSnapshot?> load(String feed) async {
    try {
      final f = await _file(feed);
      if (!await f.exists()) return null;
      final s = FeedSnapshot.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, Object?>,
      );
      return s.pages.isEmpty ? null : s;
    } catch (_) {
      // 缓存坏了就当没有，不影响主流程
      return null;
    }
  }

  static Future<void> save(String feed, FeedSnapshot snap) async {
    if (snap.pages.isEmpty) return;
    try {
      await _atomicWrite(await _file(feed), jsonEncode(snap.toJson()));
    } catch (_) {}
  }

  static Future<void> clear(String feed) async {
    try {
      final f = await _file(feed);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 单条微博缓存，**按微博 id 命名**：`status/<id>.json`。
///
/// 「怎么知道某条微博有没有缓存」—— 就是**文件是否存在**。
/// 用 id 当文件名是最省事的做法：不用维护索引、O(1) 判断、
/// 也不会出现「索引和文件不同步」这种烂账。
class StatusCache {
  static Future<File> _file(String id) async =>
      File('${(await _sub('status')).path}/$id.json');

  /// 有缓存吗（= 文件存在吗）
  static Future<bool> has(String id) async {
    try {
      return await (await _file(id)).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> load(String id) async {
    try {
      final f = await _file(id);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String id, String raw) async {
    if (raw.isEmpty) return;
    try {
      await _atomicWrite(await _file(id), raw);
    } catch (_) {}
  }

  /// 缓存条数（「我的」页展示用，也方便排查）
  static Future<int> count() async {
    try {
      final d = await _sub('status');
      return d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clearAll() async {
    try {
      final d = await _sub('status');
      for (final e in d.listSync()) {
        if (e is File) await e.delete();
      }
    } catch (_) {}
  }
}

/// 「你上次刷到这里」锚点：每个信息流记**一条微博 id**（`marker/<feed>.txt`）。
///
/// 为什么记 id 而不是「列表第几条」：index 会被刷新、去重、广告过滤弄漂；
/// id 不会。而且微博 id **单调递增** —— 越新的 id 越大，所以
/// 「谁在更靠下的位置」可以**纯靠数字比较**得出（见 `isOlderId`）。
class ReadMarker {
  static Future<File> _file(String feed) async =>
      File('${(await _sub('marker')).path}/$feed.txt');

  static Future<String?> load(String feed) async {
    try {
      final f = await _file(feed);
      if (!await f.exists()) return null;
      final s = (await f.readAsString()).trim();
      return s.isEmpty ? null : s;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String feed, String id) async {
    if (id.isEmpty) return;
    try {
      await _atomicWrite(await _file(feed), id);
    } catch (_) {}
  }

  static Future<void> clear(String feed) async {
    try {
      final f = await _file(feed);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
