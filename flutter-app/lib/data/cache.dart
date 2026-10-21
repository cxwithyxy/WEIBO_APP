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

  static Future<bool> save(String id, String raw) async {
    if (raw.isEmpty) return false;
    try {
      await _atomicWrite(await _file(id), raw);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 删掉某条微博的缓存。写操作后刷新失败时用它兜底：**绝不允许旧数据继续骗人**。
  static Future<void> remove(String id) async {
    try {
      final f = await _file(id);
      if (await f.exists()) await f.delete();
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

/// 「你上次刷到这里」+「上次离开时的位置」：每个信息流一个文件
/// （`marker/<feed>.json`）。
///
/// 三样东西一起存：
///
///  1. `id` —— 上次刷到的**最深处**那条微博 id。这是列表里分隔条
///     （`LastSeenBar`）的语义：它以上 = 看过的，以下 = 没看的。只增不减。
///     之所以记 id 而不是「列表第几条」：index 会被刷新、去重、广告过滤弄漂；
///     id 不会（微博 id **单调递增** → 大小关系就是先后关系）。
///  2. `offset` —— 离开时列表的**像素滚动偏移**。「回到离开的地方」靠它。
///  3. `topId` —— 离开时**视口顶部**那条的 id，恢复后用来**校验落点**。
///
/// 为什么敢用像素偏移这种「脆弱」的东西：缓存里存的是服务端**响应原文**，
/// 重开时走同一套解析还原 → 条目顺序和每条的高度都跟离开时一模一样，
/// 所以同一个偏移量必然落在同一条上。id 依然保留，因为它**不依赖下标**。
class ReadMarker {
  const ReadMarker({required this.id, this.offset, this.topId});

  /// 最深处那条微博 id（非空才有意义）
  final String id;

  /// 离开时列表的滚动偏移（像素）；未知为 null
  final double? offset;

  /// 离开时视口顶部那条的 id；未知为 null
  final String? topId;

  static Future<File> _json(String feed) async =>
      File('${(await _sub('marker')).path}/$feed.json');

  /// v1 的老格式：文件里只有一个 id 的纯文本
  static Future<File> _legacy(String feed) async =>
      File('${(await _sub('marker')).path}/$feed.txt');

  static Future<ReadMarker?> load(String feed) async {
    try {
      final f = await _json(feed);
      if (await f.exists()) {
        final m = jsonDecode(await f.readAsString()) as Map<String, Object?>;
        final id = m['id']?.toString().trim() ?? '';
        if (id.isEmpty) return null;
        return ReadMarker(
          id: id,
          offset: (m['offset'] as num?)?.toDouble(),
          topId: m['topId']?.toString(),
        );
      }
      // 兼容老格式：只有 id，没有位置（位置就退回顶部）
      final l = await _legacy(feed);
      if (!await l.exists()) return null;
      final id = (await l.readAsString()).trim();
      return id.isEmpty ? null : ReadMarker(id: id);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String feed, ReadMarker m) async {
    if (m.id.isEmpty) return;
    try {
      await _atomicWrite(
        await _json(feed),
        jsonEncode({'id': m.id, 'offset': m.offset, 'topId': m.topId}),
      );
      // 老文件清掉，免得下次读到过期数据
      final l = await _legacy(feed);
      if (await l.exists()) await l.delete();
    } catch (_) {}
  }

  static Future<void> clear(String feed) async {
    try {
      for (final f in [await _json(feed), await _legacy(feed)]) {
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }
}
