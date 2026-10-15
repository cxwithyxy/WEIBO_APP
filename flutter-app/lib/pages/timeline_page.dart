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

  /// 本次会话滚到的最深处（微博 id，越小越靠下）—— 防抖写盘
  String? _seenId;
  Timer? _saveTimer;
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
      final anchor = await ReadMarker.load(_feedKey);
      if (!mounted) return;
      setState(() {
        _markerAnchorId = anchor;
        _seenId = anchor;
      });
      await _loadFromCache();
      await refresh();
    });
  }

  @override
  void dispose() {
    // 用户要求「后退离开列表页时记录」——这里兜底再写一次。
    // 平时滚动停止时就已防抖写过盘，所以这一步基本是幂等的；
    // 之所以不只靠 dispose，是因为本页 keepAlive，切 tab 时根本不会 dispose。
    _saveTimer?.cancel();
    final id = _seenId;
    if (id != null) unawaited(ReadMarker.save(_feedKey, id));
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
  Future<void> _loadFromCache() async {
    final snap = await FeedCache.load(_feedKey);
    if (snap == null) return;
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
    if (!mounted || all.isEmpty) return;
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

  /// 滚动停止 → 记录「刷到的最深处」。
  ///
  /// 只用 id 比较，**不依赖下标** —— 所以刷新、去重、广告过滤都不会让它漂。
  /// 而且不只在 dispose 记录：本页 keepAlive，切 tab 不会 dispose。
  void _onScrollEnd() {
    if (!mounted || _items.isEmpty) return;
    final entries = _entries(_visibleItems());
    final idx = _bottomEntryIndex();
    if (idx == null || idx < 0 || idx >= entries.length) return;
    final e = entries[idx];
    if (e is! StatusDto) return; // 正好停在锚点那一行，跳过
    final id = e.id;
    final cur = _seenId;
    if (cur != null && !_isOlder(id, cur)) return; // 没比已记录的更深 → 不动
    _seenId = id;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      final v = _seenId;
      if (v != null) unawaited(ReadMarker.save(_feedKey, v));
    });
  }

  /// 视口**最下面**那条在 child 序列里的下标。
  ///
  /// 为什么不用「已构建的最大下标」：`ListView` 会预先构建视口外约 250px
  /// （cacheExtent），最大下标会偏下 1 条左右。
  ///
  /// 这里只用**公开** API（`visitChildren` / `childScrollOffset` / `indexOf`）：
  /// 逐个已构建的孩子看它的起始偏移，取「起点仍在视口底部之上」的最后一个。
  int? _bottomEntryIndex() {
    final ctx = _listKey.currentContext;
    if (ctx == null || !_scroll.hasClients) return null;
    final root = ctx.findRenderObject();
    if (root == null) return null;

    RenderSliverMultiBoxAdaptor? sliver;
    void visit(RenderObject o) {
      if (sliver != null) return;
      if (o is RenderSliverMultiBoxAdaptor) {
        sliver = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(root);
    final s = sliver;
    if (s == null) return null;

    final p = _scroll.position;
    final viewportBottom = p.pixels + p.viewportDimension;

    var best = -1;
    s.visitChildren((child) {
      if (child is! RenderBox) return;
      final top = s.childScrollOffset(child);
      if (top == null) return;
      if (top <= viewportBottom) best = s.indexOf(child);
    });
    return best < 0 ? null : best;
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
