import 'package:flutter/material.dart';

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
      await _loadFromCache();
      await refresh();
    });
  }

  @override
  void dispose() {
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
        final visible = Settings.instance.hideAds
            ? _items.where((s) => !s.isAd).toList(growable: false)
            : _items;
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView.separated(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: visible.length + 1,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == visible.length) {
                return FooterHint(loading: _loading, hasMore: _hasMore);
              }
              final s = visible[i];
              return StatusCard(
                status: s,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => DetailPage(mid: s.id)),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
