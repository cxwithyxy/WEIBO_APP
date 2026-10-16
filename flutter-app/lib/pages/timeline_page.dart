import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/cache.dart';
import '../session.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../util/dedup.dart';
import '../util/marker_place.dart';
import '../widgets/common.dart';
import '../widgets/status_card.dart';
import 'detail_page.dart';

enum TimelineKind { home, following }

/// 时间线页。两种模式复用同一套代码：
///
///  - `home`：首页（关注的人 + 推荐），**游标**翻页（`since_id` / `next_cursor`）
///  - `following`：纯关注流，时间序；该端点 `since_id` 实测无效，用**页码**翻页
///
/// 本地缓存策略（对齐原 Android 版 `FeedCache`）：
///   1. 进页面先用缓存渲染（秒开，不转圈），再去网络刷新；
///   2. 每次成功请求把**响应原文**追加进缓存，并一起存下游标；
///   3. 重开时用 core 的 `parseTimelineRaw` 解析原文 —— 与网络路径同一套解析。
class TimelinePage extends StatefulWidget {
  const TimelinePage({
    super.key,
    required this.kind,
    this.onNeedLogin,
    this.controller,
  });

  final TimelineKind kind;
  final VoidCallback? onNeedLogin;

  /// 外部传入的滚动控制器（供「双击顶部回顶部」使用）；为空时自建
  final ScrollController? controller;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _items = <StatusDto>[];

  /// 已出现过的微博 id —— 跨页去重用（见 util/dedup.dart）
  final _seen = <String>{};

  /// 列表 key —— 用来从 RenderSliver 精确取「视口最下面那条」的下标
  final _listKey = GlobalKey();

  /// 「你上次刷到这里」锚点：进页面时从磁盘读一次，**本次会话固定不动**
  ///
  /// 它是**常驻**的：即使锚点那条微博当前不在列表里（被翻页裁掉等），
  /// `_entries()` 也会用 id 大小把它插到正确的相对位置 —— 不能让标记凭空消失。
  String? _markerAnchorId;

  /// 本次会话看见过的**最深**一条（只存内存，`_deepestId` 是它的微博 id）。
  ///
  /// ⚠️ 「更深」用**列表下标**（`_deepestIndex`）判断，**不能**用 id 大小：
  /// 关注流里会夹着**置顶微博**（id 很小、却排在最前），一旦拿 id 比大小，
  /// 标记就会被置顶那条钉死、之后永远不再推进 ——
  /// 真机上的表现就是「不管怎么滑，标记都挂在顶部」。
  ///
  /// 只在内存里跟 —— **不落盘**。用户要求：滚动过程中不更新标记，
  /// 只有 App 切后台或退出时，才把它写下去当作新的「上次刷到这里」。
  String? _deepestId;
  int _deepestIndex = -1;

  /// 离开时列表的滚动偏移 + 视口顶部那条的 id —— 「回到离开的地方」用
  double? _savedOffset;
  String? _savedTopId;

  /// 正在做「恢复位置」：这段时间的滚动是程序跳的，不该污染盘上的离开位置
  bool _restoring = false;

  /// 恢复位置最多纠偏几次（懒加载列表的 maxScrollExtent 只是估算值）
  static const _restoreAttempts = 3;

  /// 「你上次刷到这里」那条标记条的大致高度 —— 判断「完整可见」时留的余量
  static const _markerBarHeight = 48.0;
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;

  /// 已缓存的响应原文（一页一条）
  final _pages = <String>[];

  String _cursor = '';
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  /// 缓存文件名：home / following
  String get _feedKey =>
      widget.kind == TimelineKind.home ? 'home' : 'following';

  @override
  void initState() {
    super.initState();
    // 监听 App 级生命周期：切后台 / 退回前台 / 进程分离 —— 见 didChangeAppLifecycleState
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 锚点要在渲染前就绪（否则列表先出来、标记再插进去会跳一下）
      final m = await ReadMarker.load(_feedKey);
      if (!mounted) return;
      setState(() {
        _markerAnchorId = m?.id;
        _deepestId = m?.id;
        _savedOffset = m?.offset;
        _savedTopId = m?.topId;
      });
      final restored = await _loadFromCache();
      if (!mounted) return;
      _ensureMarkerAnchor();
      // ★ 有缓存就**不自动刷新**。
      //   之前这里无条件 refresh()，而 refresh() 会把整个列表换成最新一页
      //   → 上次刷到的位置连同那些旧条目一起被冲掉，「上次刷到哪」等于没生效
      //   （用户反馈的正是这个）。要新内容就下拉刷新（滚到顶再拉）。
      if (restored) {
        _restoreScroll();
      } else {
        await refresh();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 退出/离场时的兜底：本页 keepAlive，切 tab 不会 dispose，
    // 所以「关闭 App」「返回退出」主要靠 didChangeAppLifecycleState。
    unawaited(_commitMarker());
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  /// 切后台 / 退出 —— 用户要求：**只有这两个时机**才更新「上次刷到这里」。
  ///
  /// 这几种状态都算「离开」：
  ///  - `inactive`：切到后台/来电/多任务面板（最灵敏，先落盘）
  ///  - `hidden`：完全被遮住
  ///  - `paused`：进入后台（Android 上就是这个）
  ///  - `detached`：View 已分离、进程即将结束
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        unawaited(_commitMarker());
      case AppLifecycleState.resumed:
        break;
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      _more();
    }
  }

  /// 用缓存先渲染（秒开）。缓存里存的是原文，用 core 的解析路径还原。
  ///
  /// 返回：**是否真的填进了内容**（调用方据此决定「恢复位置」还是「拉网络」）。
  Future<bool> _loadFromCache() async {
    final snap = await FeedCache.load(_feedKey);
    if (snap == null) return false;
    // 缓存存的是每页原文；页与页之间本来就重叠（服务端给的就这样），
    // 所以还原时同样要走 id 去重，否则秒开那一下就是「重复满屏」。
    final seen = <String>{};
    final all = <StatusDto>[];
    for (final raw in snap.pages) {
      try {
        all.addAll(
          dedupById(await api.parseTimelineRaw(raw: raw), (s) => s.id, seen: seen),
        );
      } catch (_) {
        // 单页解析失败就跳过这一页，不拖垮整块缓存
      }
    }
    if (!mounted || all.isEmpty) return false;
    setState(() {
      _items
        ..clear()
        ..addAll(all);
      _seen
        ..clear()
        ..addAll(seen);
      _pages
        ..clear()
        ..addAll(snap.pages);
      _cursor = snap.cursor ?? '';
      // 缓存里已经有 N 页，页码从 N+1 继续
      _page = snap.pages.length + 1;
      _hasMore = true;
    });
    return true;
  }

  /// 把「本次看见过的最深一条 + 离开时的位置」写盘成新的「上次刷到这里」。
  ///
  /// **只在切后台 / 退出时调用**（用户要求：滚动时不动标记，刷新也不动标记）。
  Future<void> _commitMarker() async {
    if (_restoring) return; // 恢复途中跳来跳去的中间态不写盘
    // 位置（offset/topId）每次都要存，否则「回到离开的地方」会失效；
    // 标记 id 优先用本会话真的读到的位置，没读过则沿用原来的锚点。
    final id = _deepestId ?? _markerAnchorId;
    if (id == null || id.isEmpty) return;
    await ReadMarker.save(
      _feedKey,
      ReadMarker(id: id, offset: _savedOffset, topId: _savedTopId),
    );
  }

  /// 保证「始终有一个标记」：磁盘上没有（首次装、标记文件被清）就取当前第一条。
  ///
  /// 用户反馈「还是看不到标记」，根因就是没标记时 `_entries()` 什么也不插 ——
  /// 现在没标记也会就地立一个，列表里总能看到这条分割线。
  void _ensureMarkerAnchor() {
    if (_markerAnchorId != null) return;
    final vis = _visibleItems();
    if (vis.isEmpty) return;
    _markerAnchorId = vis.first.id;
    _deepestId ??= vis.first.id;
  }

  Future<void> _persist() =>
      FeedCache.save(_feedKey, FeedSnapshot(pages: List.of(_pages), cursor: _cursor));

  Future<TimelineRawDto> _fetchRaw({required bool first}) {
    if (widget.kind == TimelineKind.home) {
      return api.homeTimelinePageRaw(sinceId: first ? '' : _cursor, count: 20);
    }
    return api.followingTimelinePageRaw(page: first ? 1 : _page, count: 20);
  }

  /// 首页流的游标还能继续翻吗？
  ///
  /// ⚠️ 游标为空时**必须停**：`since_id` 传空串会被 core 归一化成 `"0"`，
  /// 那等于「再给我第一页」→ 无限重复同一批内容。关注流用页码翻页，不适用。
  bool _cursorAdvanced(String next, String prev) =>
      widget.kind != TimelineKind.home || (next.isNotEmpty && next != prev);

  Future<void> refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _fetchRaw(first: true);
      if (!mounted) return;
      // 同一页内部也可能重复（置顶 + 原条目），先按 id 去重
      final fresh = dedupById(p.statuses, (s) => s.id);
      final cursor = p.nextCursor ?? '';
      setState(() {
        if (_items.isEmpty) {
          // 首次：整页铺开
          _items
            ..clear()
            ..addAll(fresh);
          _seen
            ..clear()
            ..addAll(fresh.map((s) => s.id));
          _pages.clear();
          if (p.raw.isNotEmpty) _pages.add(p.raw);
          _cursor = cursor;
          _page = 2;
          _hasMore = p.statuses.length >= 20 && _cursorAdvanced(cursor, '');
        } else {
          // 已有内容：**只往前面插入「从未见过的新微博」**，其余原地不动。
          //
          // 为什么要 prepend 而不是整页替换：替换会把锚点那条一并冲掉，
          // 「上次刷到这里」的分割线就没了 —— 用户反馈的正是这个。
          // 插到前面后，锚点仍在列表里、且在内容上的位置不变。
          // `_cursor` / `_page` 同样**不能动**：那是「继续往下翻旧内容」用的。
          final newOnes = fresh
              .where((s) => !_seen.contains(s.id))
              .toList(growable: false);
          if (newOnes.isNotEmpty) {
            _items.insertAll(0, newOnes);
            _seen.addAll(newOnes.map((s) => s.id));
            // 缓存存的是原文：新页插到最前，重开时按顺序解析 + 去重，
            // 第一条优先保留 → 还原出来的顺序与新页在前一致。
            if (p.raw.isNotEmpty) _pages.insert(0, p.raw);
          }
        }
        _ensureMarkerAnchor();
      });
      await _persist();
    } catch (e) {
      if (!mounted) return;
      // 有缓存时网络失败不覆盖屏幕（继续看缓存），只提示
      if (_items.isEmpty) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loading || !_hasMore || _error != null) return;
    setState(() => _loading = true);
    final prevCursor = _cursor;
    try {
      final p = await _fetchRaw(first: false);
      if (!mounted) return;
      // ★ 防重复的关键：与**已有条目**按 id 去重后再追加（见 util/dedup.dart）
      final fresh = dedupById(p.statuses, (s) => s.id, seen: _seen);
      final next = p.nextCursor ?? '';
      setState(() {
        _items.addAll(fresh);
        if (p.raw.isNotEmpty) _pages.add(p.raw);
        if (next.isNotEmpty) _cursor = next;
        _page += 1;
        // 游标没前进（或拿不到游标）= 服务端在重复给同一批 → 停，别再拉
        _hasMore = p.statuses.isNotEmpty && _cursorAdvanced(next, prevCursor);
      });
      await _persist();
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ------------------------------------------------- 「上次刷到这里」锚点

  /// 当前实际展示的条目（hideAds 过滤口径必须和 build 里一致）
  List<StatusDto> _visibleItems() => Settings.instance.hideAds
      ? _items.where((s) => !s.isAd).toList(growable: false)
      : _items;

  /// 锚点在 visible 中的下标；没锚点或不在列表里 → -1
  int _markerAt(List<StatusDto> visible) {
    final id = _markerAnchorId;
    if (id == null) return -1;
    return visible.indexWhere((s) => s.id == id);
  }

  /// 把 visible 展开成实际渲染序列：微博条目 + （始终一条）锚点占位
  List<Object> _entries(List<StatusDto> visible) {
    final out = <Object>[];
    if (visible.isEmpty) return out;
    final at = _markerAt(visible);
    if (at >= 0) {
      for (var i = 0; i < visible.length; i++) {
        out.add(visible[i]);
        // 用户要的效果：C（上次刷到的）和 D（更早的）之间
        if (i == at) out.add(const _MarkerToken());
      }
      return out;
    }

    // 锚点那条当前不在列表里（被翻页裁掉 / 刷掉了）——
    // **不能让标记凭空消失**，按 id 找它“本该在”的位置（见 util/marker_place.dart，
    // 那里有测试锁着方向 + 置顶微博的坑）。
    final id = _markerAnchorId;
    if (id == null) return List<Object>.of(visible);
    final pos = markerInsertIndex(visible.map((s) => s.id).toList(), id);
    for (var i = 0; i < visible.length; i++) {
      if (i == pos) out.add(const _MarkerToken());
      out.add(visible[i]);
    }
    if (pos >= visible.length) out.add(const _MarkerToken());
    return out;
  }

  /// 滚动停止 → 记两样东西：
  ///
  ///  ① **未读边界**：视口最下面那条。只在「比已记录的更深」时才推进
  ///     —— 纯 id 比较，**不依赖下标**，所以刷新/去重/广告过滤都不会让它漂。
  ///  ② **离开时的位置**：当前像素偏移 + 视口顶部那条的 id。滚上滚下都要跟。
  ///
  /// 顺带一个细节：本页 keepAlive，切 tab 不会 dispose，所以不能只靠 dispose 记录。
  void _onScrollEnd() {
    if (_restoring) return;
    if (!mounted || _items.isEmpty || !_scroll.hasClients) return;
    final entries = _entries(_visibleItems());

    // 离开时的位置：滚上滚下都跟（只存内存，切后台/退出时一起落盘）
    _savedOffset = _scroll.position.pixels;
    final topIdx = _edgeEntryIndex(bottom: false);
    if (topIdx != null && topIdx >= 0 && topIdx < entries.length) {
      final e = entries[topIdx];
      _savedTopId = e is StatusDto ? e.id : null;
    }

    // 本次「刷到」的锚点：视口里**完整可见的最后一条**（见 _lastFullyVisibleIndex）；
    // 整屏长图帖、一条都不完整时，退回视口顶部那条 —— 无论哪种都保证标记在屏内。
    final anchorIdx = _lastFullyVisibleIndex() ?? _edgeEntryIndex(bottom: false);

    // 只推内存，**不落盘**：用户要求标记只在切后台/退出时更新。
    // 「更深」按下标比（见 `_deepestIndex` 注释），不能按 id 大小。
    if (anchorIdx != null && anchorIdx >= 0 && anchorIdx < entries.length) {
      final e = entries[anchorIdx];
      if (e is StatusDto && anchorIdx > _deepestIndex) {
        _deepestIndex = anchorIdx;
        _deepestId = e.id;
      }
    }
  }

  /// 列表内部的 Sliver（拿不到就 null）
  RenderSliverMultiBoxAdaptor? _sliver() {
    final ctx = _listKey.currentContext;
    if (ctx == null || !_scroll.hasClients) return null;
    final root = ctx.findRenderObject();
    if (root == null) return null;

    RenderSliverMultiBoxAdaptor? found;
    void visit(RenderObject o) {
      if (found != null) return;
      if (o is RenderSliverMultiBoxAdaptor) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// **视口边界**那一条在 child 序列里的下标。
  ///
  /// `bottom: true`  → 视口**最下面**那条（起点仍在视口底部之上的最大下标）
  /// `bottom: false` → 视口**最上面**那条（起点仍在视口顶部之下的最大下标）
  ///
  /// 两者其实是同一个式子，只是「界线」不同 —— 因为 child 序列的顺序
  /// 就是偏移量的顺序（下标越大越靠下）。
  ///
  /// 为什么不用「已构建的最大下标」：`ListView` 会预先构建视口外约 250px
  /// （cacheExtent），最大下标会偏下 1 条左右。
  ///
  /// 这里只用**公开** API（`visitChildren` / `childScrollOffset` / `indexOf`）。
  int? _edgeEntryIndex({required bool bottom}) {
    final s = _sliver();
    if (s == null || !_scroll.hasClients) return null;
    final p = _scroll.position;
    final limit = bottom ? p.pixels + p.viewportDimension : p.pixels;

    var best = -1;
    s.visitChildren((child) {
      if (child is! RenderBox) return;
      final top = s.childScrollOffset(child);
      if (top == null || top > limit) return;
      // `indexOf` 返回非空 int，不必判空
      final i = s.indexOf(child);
      if (i > best) best = i;
    });
    return best < 0 ? null : best;
  }

  /// 视口里**完整可见的最后一条**的下标（带一点余量，保证它后面的标记条也在屏内）。
  ///
  /// 为什么不用「视口最下面那条」：那条底部被切掉，标记插在它后面会掉到
  /// **屏幕下沿之外** —— 重开时用户看不到标记，以为功能没生效（真机反馈）。
  /// 整屏都是长图帖（没有一条完整可见）时返回 null，调用方退回视口顶部那条。
  int? _lastFullyVisibleIndex() {
    final s = _sliver();
    if (s == null || !_scroll.hasClients) return null;
    final p = _scroll.position;
    // 留 _markerBarHeight 的余量：让「锚点那条 + 它下面的标记条」都在屏内
    final limit = p.pixels + p.viewportDimension - _markerBarHeight;
    var best = -1;
    s.visitChildren((child) {
      if (child is! RenderBox) return;
      final top = s.childScrollOffset(child);
      if (top == null) return;
      if (top + child.size.height > limit) return; // 底部够不到 → 不算完整可见
      final i = s.indexOf(child);
      if (i > best) best = i;
    });
    return best < 0 ? null : best;
  }

  /// 已构建条目的平均高度 —— 估算「还要往下几条」对应多少像素用。
  /// 懒加载列表里，没建出来的条目根本没有确切偏移，只能先估再量（见 `_restorePass`）。
  double? _avgEntryExtent() {
    final s = _sliver();
    if (s == null) return null;
    int? lo;
    int? hi;
    double? loOff;
    double? hiOff;
    s.visitChildren((child) {
      if (child is! RenderBox) return;
      final i = s.indexOf(child);
      final off = s.childScrollOffset(child);
      if (off == null) return;
      if (lo == null || i < lo!) {
        lo = i;
        loOff = off;
      }
      if (hi == null || i > hi!) {
        hi = i;
        hiOff = off;
      }
    });
    if (lo == null || hi == null || loOff == null || hiOff == null) return null;
    final n = hi! - lo!;
    if (n <= 0) return null;
    final avg = (hiOff! - loOff!) / n;
    return avg > 1 ? avg : null;
  }

  // ------------------------------------------------- 恢复「离开时的位置」

  /// 回到上次离开的地方。
  ///
  /// 为什么要「跳 → 量 → 修正」而不是跳一次就完事：`ListView` 是懒加载的，
  /// 没建出来的条目**没有确切偏移**，`maxScrollExtent` 在那一刻只是**估算值**。
  /// 如果目标偏移比估算的还大，`jumpTo` 会被夹住 —— 所以跳完量一下落点，
  /// 不对就按「还差几条 × 平均条高」补跳，最多 `_restoreAttempts` 次。
  void _restoreScroll() {
    final off = _savedOffset;
    if (off == null || off <= 0) return;
    _restoring = true;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restorePass(off, _savedTopId, 0),
    );
  }

  void _restorePass(double target, String? wantTopId, int attempt) {
    if (!mounted || !_scroll.hasClients) {
      _finishRestore();
      return;
    }
    final pos = _scroll.position;
    pos.jumpTo(target.clamp(0.0, pos.maxScrollExtent).toDouble());

    // 下一帧才量得准（刚跳完，布局可能还没收敛）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        _finishRestore();
        return;
      }
      if (wantTopId == null) {
        _finishRestore(); // 没有校验依据 → 认了
        return;
      }
      final entries = _entries(_visibleItems());
      final idx = _edgeEntryIndex(bottom: false);
      final at = (idx != null && idx >= 0 && idx < entries.length)
          ? entries[idx]
          : null;
      if (at is StatusDto && at.id == wantTopId) {
        _finishRestore(); // ✓ 落点正确
        return;
      }
      if (attempt >= _restoreAttempts) {
        _finishRestore(); // 放弃纠偏，保持现状（差几条不影响用）
        return;
      }
      final k = entries.indexWhere((e) => e is StatusDto && e.id == wantTopId);
      final avg = _avgEntryExtent();
      if (k < 0 || idx == null || avg == null) {
        _finishRestore();
        return;
      }
      _restorePass(
        _scroll.position.pixels + (k - idx) * avg,
        wantTopId,
        attempt + 1,
      );
    });
  }

  void _finishRestore() {
    if (!_restoring) return;
    _restoring = false;
    _onScrollEnd(); // 把真实落点写回盘上
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_error != null && _items.isEmpty) {
      return ErrorView(error: _error!, onRetry: refresh);
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          children: const [
            SizedBox(height: 160),
            EmptyView(text: '还没有内容', icon: Icons.dynamic_feed_outlined),
          ],
        ),
      );
    }

    // 「关闭广告」（设置页可切）开启时过滤掉推广微博；
    // 用 AnimatedBuilder 监听 Settings，切换后回到列表**立即生效**。
    return AnimatedBuilder(
      animation: Settings.instance,
      builder: (context, _) {
        final visible = _visibleItems();
        final entries = _entries(visible);
        return RefreshIndicator(
          onRefresh: refresh,
          child: NotificationListener<ScrollEndNotification>(
            onNotification: (_) {
              _onScrollEnd();
              return false;
            },
            child: ListView.builder(
              key: _listKey,
              controller: _scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: entries.length + 1,
              itemBuilder: (context, i) {
                if (i == entries.length) {
                  return FooterHint(loading: _loading, hasMore: _hasMore);
                }
                final e = entries[i];
                if (e is _MarkerToken) return const LastSeenBar();
                final s = e as StatusDto;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusCard(
                      status: s,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => DetailPage(mid: s.id)),
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// 列表里的锚点占位（不是真实微博，只是插在序列里的一个位置标记）
class _MarkerToken {
  const _MarkerToken();
}

/// 「你上次刷到这里」细分隔条
class LastSeenBar extends StatelessWidget {
  const LastSeenBar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final line = Divider(color: c.outlineVariant, height: 1, thickness: 1);
    return Container(
      color: c.secondaryContainer.withAlpha(76),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: [
          Expanded(child: line),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.bookmark_outline, size: 14, color: c.primary),
                const SizedBox(width: 4),
                Text(
                  '你上次刷到这里',
                  style: TextStyle(fontSize: 12, color: c.primary),
                ),
              ],
            ),
          ),
          Expanded(child: line),
        ],
      ),
    );
  }
}
