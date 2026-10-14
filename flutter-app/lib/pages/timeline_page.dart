import 'package:flutter/material.dart';

import '../data/cache.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
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
    final all = <StatusDto>[];
    for (final raw in snap.pages) {
      try {
        all.addAll(await api.parseTimelineRaw(raw: raw));
      } catch (_) {
        // 单页解析失败就跳过这一页，不拖垮整块缓存
      }
    }
    if (!mounted || all.isEmpty) return;
    setState(() {
      _items
        ..clear()
        ..addAll(all);
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

  Future<void> refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _fetchRaw(first: true);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.statuses);
        _pages.clear();
        if (p.raw.isNotEmpty) _pages.add(p.raw);
        _cursor = p.nextCursor ?? '';
        _page = 2;
        _hasMore = p.statuses.length >= 20;
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
    try {
      final p = await _fetchRaw(first: false);
      if (!mounted) return;
      setState(() {
        _items.addAll(p.statuses);
        if (p.raw.isNotEmpty) _pages.add(p.raw);
        _cursor = p.nextCursor ?? _cursor;
        _page += 1;
        _hasMore = p.statuses.isNotEmpty;
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

    return RefreshIndicator(
      onRefresh: refresh,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _items.length) {
            return FooterHint(loading: _loading, hasMore: _hasMore);
          }
          final s = _items[i];
          return StatusCard(
            status: s,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => DetailPage(mid: s.id)),
            ),
          );
        },
      ),
    );
  }
}
