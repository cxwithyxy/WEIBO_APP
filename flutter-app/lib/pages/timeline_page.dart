import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/cache.dart';
import '../session.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../util/dedup.dart';
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

class _TimelinePageState extends State<TimelinePage> with AutomaticKeepAliveClientMixin {
  final _items = <StatusDto>[];

  /// 已出现过的微博 id —— 跨页去重用（见 util/dedup.dart）
  final _seen = <String>{};

  /// 列表 key —— 用来从 RenderSliver 精确取「视口最下面那条」的下标
  final _listKey = GlobalKey();

  /// 「你上次刷到这里」锚点：进页面时从磁盘读一次，**本次会话固定不动**
  String? _markerAnchorId;

  /// 本次会话滚到的最深处（微博 id，越小越靠下）—— 未读边界，只增不减
  String? _seenId;

  /// 离开时列表的滚动偏移 + 视口顶部那条的 id —— 「回到离开的地方」用
  double? _savedOffset;
  String? _savedTopId;
  Timer? _saveTimer;

  /// 正在做「恢复位置」：这段时间的滚动是程序跳的，不该污染盘上的离开位置
  bool _restoring = false;

  /// 恢复位置最多纠偏几次（懒加载列表的 maxScrollExtent 只是估算值）
  static const _restoreAttempts = 3;
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
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 锚点要在渲染前就绪（否则列表先出来、标记再插进去会跳一下）
      final m = await ReadMarker.load(_feedKey);
      if (!mounted) return;
      setState(() {
        _markerAnchorId = m?.id;
        _seenId = m?.id;
        _savedOffset = m?.offset;
        _savedTopId = m?.topId;
      });
      final restored = await _loadFromCache();
      if (!mounted) return;
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
    // 用户要求「后退离开列表页时记录」——这里兜底再写一次。
    // 平时滚动停止时就已防抖写过盘，所以这一步基本是幂等的；
    // 之所以不只靠 dispose，是因为本页 keepAlive，切 tab 时根本不会 dispose。
    _saveTimer?.cancel();
    unawaited(_saveMarkerNow());
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
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

  /// 把「未读边界 + 离开时的位置」写盘（防抖与 dispose 都走这里）
  Future<void> _saveMarkerNow() async {
    if (_restoring) return; // 恢复途中跳来跳去的中间态不写盘
    final id = _seenId;
    if (id == null || id.isEmpty) return;
    await ReadMarker.save(
      _feedKey,
      ReadMarker(id: id, offset: _savedOffset, topId: _savedTopId),
    );
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(_saveMarkerNow());
    });
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
      });
      // 主动刷新 = 回到最新 → 恢复点也归零。
      // 否则下次进来会跳到「已被这次刷新丢掉」的深处（那个偏移还留着）。
      final vis = _visibleItems();
      _savedOffset = 0;
      _savedTopId = vis.isEmpty ? null : vis.first.id;
      if (_seenId == null && vis.isNotEmpty) _seenId = vis.first.id;
      await _persist();
      await _saveMarkerNow();
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

  /// 把 visible 展开成实际渲染序列：微博条目 + （可能一条）锚点占位
  List<Object> _entries(List<StatusDto> visible) {
    final at = _markerAt(visible);
    final out = <Object>[];
    for (var i = 0; i < visible.length; i++) {
      out.add(visible[i]);
      // 用户要的效果：C（上次刷到的）和 D（更早的）之间
      if (i == at) out.add(const _MarkerToken());
    }
    return out;
  }

  /// 微博 id **单调递增** → id 更小 = 发布更早 = 在列表里更靠下。
  /// 用 BigInt 比（19 位数字会超 int64），解析失败就当「不比它更早」。
  bool _isOlder(String a, String b) {
    try {
      return BigInt.parse(a) < BigInt.parse(b);
    } catch (_) {
      return false;
    }
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

    // ② 位置：无条件跟
    _savedOffset = _scroll.position.pixels;
    final topIdx = _edgeEntryIndex(bottom: false);
    if (topIdx != null && topIdx >= 0 && topIdx < entries.length) {
      final e = entries[topIdx];
      _savedTopId = e is StatusDto ? e.id : null;
    }

    // ① 边界：只有更深才推进
    final botIdx = _edgeEntryIndex(bottom: true);
    if (botIdx != null && botIdx >= 0 && botIdx < entries.length) {
      final e = entries[botIdx];
      if (e is StatusDto) {
        final cur = _seenId;
        if (cur == null || _isOlder(e.id, cur)) _seenId = e.id;
      }
    }

    _scheduleSave();
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
