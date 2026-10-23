import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../util/unread_center.dart';

/// 读/写某个 feed 的未读 id 集。抽成函数类型是为了单测能注入内存实现、
/// 绕开 path_provider（见 `UnreadStore.forTest`）。
typedef UnreadReader = Future<Set<String>> Function(String feed);
typedef UnreadWriter = Future<void> Function(String feed, Set<String> ids);

/// 未读标记的**持久化集合**（按 feed 分文件：`unread/<feed>.json`）。
///
/// 设计要点：
///  - 纯内存变更即时生效并 `notifyListeners()`，卡片监听它刷新绿点
///    （照 `AttitudeStore` 的写法）；
///  - **落盘用防抖**（默认 1s）：滚动过程中会频繁 `markReadAll`，不能每次都
///    写盘。另外在切后台/退出/刷新结束/`_more` 结束时显式 `flush()`；
///  - 读写失败一律静默吞掉，绝不影响主流程。
class UnreadStore extends ChangeNotifier {
  UnreadStore._({
    UnreadReader? reader,
    UnreadWriter? writer,
    Duration? saveDelay,
  })  : _reader = reader ?? _fileRead,
        _writer = writer ?? _fileWrite,
        _saveDelay = saveDelay ?? const Duration(seconds: 1);

  /// App 全局单例。
  static final UnreadStore instance = UnreadStore._();

  /// 单测用：注入内存读写 + 很短的防抖。
  @visibleForTesting
  static UnreadStore forTest({
    required UnreadReader reader,
    required UnreadWriter writer,
    Duration saveDelay = const Duration(milliseconds: 5),
  }) =>
      UnreadStore._(reader: reader, writer: writer, saveDelay: saveDelay);

  final UnreadReader _reader;
  final UnreadWriter _writer;
  final Duration _saveDelay;

  final _byFeed = <String, Set<String>>{};
  String _feed = '';
  Timer? _timer;
  bool _dirty = false;

  Set<String> get _active => _byFeed.putIfAbsent(_feed, () => <String>{});

  int get count => _active.length;

  bool contains(String id) => id.isNotEmpty && _active.contains(id);

  /// 切换/载入某个 feed 的未读集（幂等；已载入则不重新读盘）。
  Future<void> load(String feed) async {
    if (_feed == feed && _byFeed.containsKey(feed)) {
      notifyListeners();
      return;
    }
    _feed = feed;
    Set<String> ids;
    try {
      ids = await _reader(feed);
    } catch (_) {
      ids = <String>{};
    }
    _byFeed[feed] = ids;
    notifyListeners();
  }

  /// 新加载的条目算未读。
  void addAll(Iterable<String> ids) => _apply(unreadAddAll(_active, ids));

  void markRead(String id) => _apply(unreadMarkRead(_active, id));

  void markReadAll(Iterable<String> ids) =>
      _apply(unreadMarkReadAll(_active, ids));

  /// 清除全部未读，返回清掉的条数。
  int clearAll() {
    final n = _active.length;
    if (n > 0) _apply(<String>{});
    return n;
  }

  /// 剪枝：只保留仍在列表里的未读 id，防无上限膨胀。
  void retain(Iterable<String> ids) =>
      _apply(unreadRetain(_active, ids.toSet()));

  void _apply(Set<String> next) {
    if (setEquals(_active, next)) return;
    _byFeed[_feed] = next;
    _dirty = true;
    _scheduleSave();
    notifyListeners();
  }

  void _scheduleSave() {
    _timer?.cancel();
    _timer = Timer(_saveDelay, () {
      unawaited(flush());
    });
  }

  /// 立刻落盘当前 feed 的未读集（防抖到期前也可手动调）。
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    final feed = _feed;
    final ids = Set<String>.of(_active);
    try {
      await _writer(feed, ids);
    } catch (_) {
      // 落盘失败不影响主流程（内存里的未读仍然有效）
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ------------------------------------------------------------------ 默认落盘

Future<Directory> _unreadDir() async {
  final base = await getApplicationSupportDirectory();
  final d = Directory('${base.path}/unread');
  if (!await d.exists()) await d.create(recursive: true);
  return d;
}

Future<File> _unreadFile(String feed) async =>
    File('${(await _unreadDir()).path}/$feed.json');

Future<Set<String>> _fileRead(String feed) async {
  try {
    final f = await _unreadFile(feed);
    if (!await f.exists()) return <String>{};
    final j = jsonDecode(await f.readAsString());
    if (j is List) return j.whereType<String>().toSet();
  } catch (_) {
    // 缓存坏了就当没有，不影响主流程
  }
  return <String>{};
}

Future<void> _fileWrite(String feed, Set<String> ids) async {
  try {
    final f = await _unreadFile(feed);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(ids.toList()));
    await tmp.rename(f.path); // 原子写：写一半被杀也不留坏文件
  } catch (_) {
    // 落盘失败不影响主流程
  }
}
