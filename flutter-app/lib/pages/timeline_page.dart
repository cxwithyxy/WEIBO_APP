import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/cache.dart';
import '../data/unread.dart';
import '../session.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../util/dedup.dart';
import '../util/timeline_backfill.dart';
import '../util/unread_center.dart';
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

  /// 上一帧每条卡片「标题相对中线的 y」（负 = 中线以上）。
  ///
  /// 只服务于**未读穿越判定**：滚动采样时对比前后两帧，`prev >= 0 && now < 0`
  /// 才算「被推过中线」。一次滚动手势结束 / 位置还原 / 刷新重建列表后清空，
  /// 免得把布局变化（刷新插入、关广告重排）误当成用户穿越。
  final _prevTitleY = <String, double>{};

  /// 未读穿越采样的节流时间戳（毫秒）。滚动每帧都算太浪费，~120ms 一次。
  int _lastUnreadSampleMs = 0;

  /// 离开时列表的滚动偏移 + 视口顶部那条的 id —— 「回到离开的地方」用
  double? _savedOffset;
  String? _savedTopId;

  /// 正在做「恢复位置」：这段时间的滚动是程序跳的，不该污染盘上的离开位置
  bool _restoring = false;

  /// 恢复位置最多纠偏几次（懒加载列表的 maxScrollExtent 只是估算值）
  static const _restoreAttempts = 3;

  /// 每页条数（刷新补拉、翻页都必须一致，否则「本页是否满页」判不准）
  static const _pageCount = 20;
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;

  /// 已缓存的响应原文（一页一条）
  final _pages = <String>[];

  String _cursor = '';
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  /// 上次刷新补拉是否**被上限截断**（`BackfillStop.capReached`）。
  ///
  /// 用途：触到上限说明「中间可能还缺一截」，不能静默当成功。
  /// `refresh()` 命中时置 true、并弹一次 SnackBar（提示可去设置调大）+ debugPrint。
  bool _backfillHitCap = false;

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
      // 未读集要先加载好：列表首帧构建时卡片按 id 查它，绿点才准。
      await UnreadStore.instance.load(_feedKey);
      if (!mounted) return;
      // 只读位置；旧的「上次刷到这里」锚点 id 已废弃（见 ReadMarker）。
      final m = await ReadMarker.load(_feedKey);
      if (!mounted) return;
      setState(() {
        _savedOffset = m?.offset;
        _savedTopId = m?.topId;
      });
      final restored = await _loadFromCache();
      if (!mounted) return;
      // ★ 有缓存就**不自动刷新**。
      //   之前这里无条件 refresh()，而 refresh() 会把整个列表换成最新一页
      //   → 上次刷到的位置连同那些旧条目一起被冲掉。要新内容就下拉刷新。
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
    // 未读穿越判定：滚动时 ~120ms 采一次（别每帧都遍历 sliver），
    // 滚动手势结束时再补一次最终采样（见 `_onScrollEnd`）。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastUnreadSampleMs >= 120) {
      _lastUnreadSampleMs = now;
      _markUnreadCrossings();
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
      // 页码优先用落盘时记下的真实值；老缓存没这个字段才回退按页数推
      // （刷新后 `_pages` 里新页与旧页有重叠，按页数推会高估 → `_more()` 跳页）。
      _page = snap.page ?? (snap.pages.length + 1);
      _hasMore = true;
    });
    // 缓存还原**不加未读**（规则第 5 条）：它们的状态由持久化未读集决定。
    // 顺手剪枝：把已经不在缓存里的未读 id 丢掉，防无上限膨胀。
    UnreadStore.instance.retain(all.map((s) => s.id));
    _prevTitleY.clear(); // 还原出的位置不参与穿越判定
    return true;
  }

  /// 把「离开时的位置」写盘（切后台 / 退出时调用），顺带把未读集落盘。
  ///
  /// 分割条已废，这里**只存位置**（offset/topId）；旧 `id` 字段不再使用。
  Future<void> _commitMarker() async {
    if (_restoring) return; // 恢复途中跳来跳去的中间态不写盘
    await ReadMarker.save(
      _feedKey,
      ReadMarker(offset: _savedOffset, topId: _savedTopId),
    );
    await UnreadStore.instance.flush();
  }

  Future<void> _persist() => FeedCache.save(
        _feedKey,
        FeedSnapshot(pages: List.of(_pages), cursor: _cursor, page: _page),
      );

  Future<TimelineRawDto> _fetchRaw({required bool first}) {
    if (widget.kind == TimelineKind.home) {
      return api.homeTimelinePageRaw(
        sinceId: first ? '' : _cursor,
        count: _pageCount,
      );
    }
    return api.followingTimelinePageRaw(
      page: first ? 1 : _page,
      count: _pageCount,
    );
  }

  /// 首页流的游标还能继续翻吗？
  ///
  /// ⚠️ 游标为空时**必须停**：`since_id` 传空串会被 core 归一化成 `"0"`，
  /// 那等于「再给我第一页」→ 无限重复同一批内容。关注流用页码翻页，不适用。
  bool _cursorAdvanced(String next, String prev) =>
      widget.kind != TimelineKind.home || (next.isNotEmpty && next != prev);

  /// 下拉刷新。
  ///
  /// **首次（列表为空）**：整页铺开。
  ///
  /// **已有旧内容**：第一页照旧并入顶部，然后**持续往更旧方向补拉**，直到
  /// 真正接上缓存里保留的旧内容为止 —— 修 cx 报的「8:00 到 12:00 凭空消失」。
  /// 原来只拉一页：一页 20 条只覆盖最新几小时，中间的断层从来没人去拉。
  ///
  /// 补拉用**独立的本地游标**（`home` 从第一页的 nextCursor 起、`following`
  /// 本地页码从 2 起），**绝不碰** `_cursor` / `_hasMore` —— 那是用户
  /// 「继续往下翻更旧内容」的位置，刷新不该把它搞乱（`_page` 见文末说明）。
  Future<void> refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _backfillHitCap = false; // 每轮刷新重置「被上限截断」信号
    });
    try {
      final p = await _fetchRaw(first: true);
      if (!mounted) return;
      // 同一页内部也可能重复（置顶 + 原条目），先按 id 去重
      final fresh = dedupById(p.statuses, (s) => s.id);
      final cursor = p.nextCursor ?? '';

      if (_items.isEmpty) {
        // 首次：整页铺开，**不补拉**（空列表没有「旧内容」可接）
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
          _hasMore = p.statuses.length >= _pageCount &&
              _cursorAdvanced(cursor, '');
        });
        // 刚加载进来的都算未读（规则第 1 条）
        UnreadStore.instance.addAll(fresh.map((s) => s.id));
        _prevTitleY.clear();
        await _persist();
        return;
      }

      // `_items` 非空 → 第一页 + 持续补拉到接上旧内容。
      // 进循环前把「旧内容」整个快照下来，循环中不再变；补拉只看快照。
      final knownIds = Set<String>.of(_seen); // 旧内容 id 快照（停止判据用）
      final newestKnownTime = _items.first.time; // 旧内容最新时间（兜底判据）
      final oldItems = List<StatusDto>.of(_items);
      final oldPages = List<String>.of(_pages); // 页顺序与 oldItems 一致
      // 每次刷新现读设置：改完设置无需重启 App。clamp 已在 Settings 侧做过。
      final maxBackfill = Settings.instance.maxBackfillPages;

      // 本次刷新抓到的页（新 → 旧），第一页先进去，之后逐页追加。
      final fetchedPages = <List<StatusDto>>[p.statuses];
      final fetchedRaws = <String>[];
      if (p.raw.isNotEmpty) fetchedRaws.add(p.raw);

      // 每页到手就重排 + setState，内容逐页出现，不卡滚动。
      // 顺序 = fetchedPages[0] + [1] + ... + oldItems（见 mergeBackfillPages），
      // 所以第 2、3 页一定排在旧内容之前、第 1 页之后。
      void render() {
        if (!mounted) return;
        final merged = mergeBackfillPages<StatusDto>(
          existing: oldItems,
          fetchedNewestFirst: fetchedPages,
          idOf: (s) => s.id,
        );
        setState(() {
          _items
            ..clear()
            ..addAll(merged);
          // 旧快照 ∪ 合并结果：既不丢旧 id，又把新页 id 收进来给 _more 去重
          _seen
            ..clear()
            ..addAll(knownIds)
            ..addAll(merged.map((s) => s.id));
          // `_pages` 原始页顺序必须与 `_items` 完全一致：新页在前、旧页在后，
          // 否则重开时按顺序解析 + 去重会还原出错误顺序。
          _pages
            ..clear()
            ..addAll(fetchedRaws)
            ..addAll(oldPages);
        });
        // 新增卡片算未读（规则第 1 条）。只加**本次新拉到**的 id：
        // `knownIds` 是刷新前的快照，过滤掉它就避免把已读的旧条目重新标未读。
        UnreadStore.instance.addAll(
          fetchedPages
              .expand((page) => page.map((s) => s.id))
              .where((id) => id.isNotEmpty && !knownIds.contains(id)),
        );
        // 列表重建 → 穿越观测从头开始（不判定，下一次滚动才判）
        _prevTitleY.clear();
      }

      render(); // 第一页立刻上屏

      final isHome = widget.kind == TimelineKind.home;
      var localCursor = cursor; // home：独立游标，从第一页的 nextCursor 起
      var localPage = 2; // following：独立页码，从 2 起（_page 是旧编号，不用）
      var pagesFetched = 0; // 本次补拉已额外抓到的页数（第一页不算）
      var currentPage = p.statuses; // 待判断的「刚处理完的那一页」
      var currentIsFirst = true; // 首屏：跳过 id 命中判断（置顶微博会误命中）
      // 第一页本身还能不能往下：首页看游标是否前进，关注流看是否满页
      final continuable = isHome
          ? _cursorAdvanced(cursor, '')
          : p.statuses.length >= _pageCount;

      // 退出原因：区分「真接上旧内容」和「被页数上限截断」——后者必须留信号。
      BackfillStop? why = continuable
          ? backfillStopReason(
              knownIds: knownIds,
              newestKnownTime: newestKnownTime,
              page: currentPage,
              pagesFetched: pagesFetched,
              maxPages: maxBackfill,
              isFirstPage: currentIsFirst,
            )
          : BackfillStop.cursorEnd;

      while (why == null) {
        TimelineRawDto np;
        try {
          np = isHome
              ? await api.homeTimelinePageRaw(
                  sinceId: localCursor,
                  count: _pageCount,
                )
              : await api.followingTimelinePageRaw(
                  page: localPage,
                  count: _pageCount,
                );
        } catch (_) {
          // 任何一页失败 → 停止补拉，保留已拿到的内容，绝不清屏
          why = BackfillStop.failed;
          break;
        }
        if (!mounted) return;
        pagesFetched++;
        final pageList = np.statuses;
        fetchedPages.add(pageList);
        if (np.raw.isNotEmpty) fetchedRaws.add(np.raw);
        render();

        // 页间限速：60 页连打容易触发风控，每页后歇一下再拉下一页
        await Future<void>.delayed(kBackfillPageDelay);
        if (!mounted) return;

        // 停止条件 (d)：游标没前进（home）/ 本页不足一页（following）
        if (isHome) {
          final next = np.nextCursor ?? '';
          final advanced = _cursorAdvanced(next, localCursor);
          localCursor = next;
          if (!advanced) {
            why = BackfillStop.cursorEnd;
            break;
          }
        } else {
          localPage++;
          if (pageList.length < _pageCount) {
            why = BackfillStop.cursorEnd;
            break;
          }
        }
        currentPage = pageList;
        currentIsFirst = false;
        why = backfillStopReason(
          knownIds: knownIds,
          newestKnownTime: newestKnownTime,
          page: currentPage,
          pagesFetched: pagesFetched,
          maxPages: maxBackfill,
          isFirstPage: currentIsFirst,
        );
      }

      // 触到上限 = 中间可能还缺一截，**不能静默当成功**：日志留证据 + 用户可见提示。
      _backfillHitCap = why == BackfillStop.capReached;
      if (_backfillHitCap) {
        final fetchedTotal = pagesFetched + 1; // 第一页也算
        final oldestCovered =
            currentPage.isEmpty ? '?' : currentPage.last.time;
        debugPrint(
          '[timeline] 补拉触到上限（设置 $maxBackfill 页 / 本轮共抓 '
          '$fetchedTotal 页），本次最旧只覆盖到 $oldestCovered，'
          '旧内容最新是 $newestKnownTime —— 中间可能仍有断档，'
          '且下次刷新不会自动接着补',
        );
        // 一次刷新只弹一次（就在循环外，不会重复）
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '本次刷新补到上限（$maxBackfill 页）仍未接上更早的内容，'
                '中间可能有缺口；可在设置里调大「每次刷新最多补拉页数」',
              ),
            ),
          );
        }
      }

      // `following` 按**页码**翻页；刷新后服务端页号已因新内容插入而整体错位。
      // 补拉了 N 页后（本地页码走到 localPage），旧编号不再可靠 —— 有意把
      // 「继续往下翻」的起点对齐到新编号的下一页，避免下次 `_more()` 从头重复拉。
      // 一页都没补（localPage 仍为 2）时保持原值，别把已有翻页进度打回去。
      // `home` 的 `_cursor` 是「旧内容底部」的游标，补拉只填了它上面的断层，
      // 所以 `_cursor` 完全不动。
      if (!isHome && pagesFetched > 0) {
        _page = localPage;
      }

      // 剪枝：只保留列表里还存在的未读 id（防无上限膨胀）。
      UnreadStore.instance.retain(_items.map((s) => s.id));
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
      // 翻页追加的也是「刚加载进来」→ 未读；顺手剪枝防膨胀。
      UnreadStore.instance.addAll(fresh.map((s) => s.id));
      UnreadStore.instance.retain(_items.map((s) => s.id));
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

  /// 记录当前位置（视口顶部那条 + 像素偏移）。只存内存，切后台/退出时落盘。
  void _recordPosition() {
    if (!mounted || _items.isEmpty || !_scroll.hasClients) return;
    final visible = _visibleItems();
    _savedOffset = _scroll.position.pixels;
    final topIdx = _edgeEntryIndex(bottom: false);
    if (topIdx != null && topIdx >= 0 && topIdx < visible.length) {
      _savedTopId = visible[topIdx].id;
    }
  }

  /// 未读「穿越判定」采样（纯逻辑见 `util/unread_center.dart`）。
  ///
  /// 只对**当前已构建**的卡片取标题/底边位置，与上一帧对比：
  ///  - `prev >= 0 && now < 0`（标题从下往上穿过中线）→ 已读；
  ///  - 卡片底边 < 0（被推出屏幕顶部）→ 已读（需求方指定的兜底规则）；
  ///  - **首次观测就在中线以上的不算读** —— 下拉刷新后插在顶部的新微博因此
  ///    保持绿点，直到用户真的把它推走（cx 要的正是这个）。
  ///
  /// 标题位置 = 卡片顶边 + [kStatusTitleOffset]（估算，不追求像素级）。
  void _markUnreadCrossings() {
    if (_restoring || !mounted || _items.isEmpty || !_scroll.hasClients) return;
    final s = _sliver();
    if (s == null) return;
    final p = _scroll.position;
    final midline = p.viewportDimension / 2;
    final visible = _visibleItems();
    final nowTitleY = <String, double>{};
    final bottomY = <String, double>{};
    s.visitChildren((child) {
      if (child is! RenderBox) return;
      final top = s.childScrollOffset(child);
      if (top == null) return;
      final i = s.indexOf(child);
      if (i < 0 || i >= visible.length) return;
      final id = visible[i].id;
      if (id.isEmpty) return;
      final viewportTop = top - p.pixels;
      nowTitleY[id] = viewportTop + kStatusTitleOffset - midline;
      bottomY[id] = viewportTop + child.size.height;
    });
    final read = crossedToRead(
      prevTitleY: _prevTitleY,
      nowTitleY: nowTitleY,
      itemBottomY: bottomY,
    );
    if (read.isNotEmpty) UnreadStore.instance.markReadAll(read);
    _prevTitleY
      ..clear()
      ..addAll(nowTitleY);
  }

  /// 滚动停止 → 记位置 + 最后一次未读采样，然后清空穿越观测。
  ///
  /// 一次滚动手势结束就忘掉上一帧位置：下一次手势从「首次观测」重新开始，
  /// 这样刷新插入 / 关广告重排造成的布局位移不会被误判成用户穿越。
  ///
  /// 本页 keepAlive，切 tab 不会 dispose，所以位置不能只靠 dispose 记录。
  void _onScrollEnd() {
    if (_restoring) return;
    if (!mounted || _items.isEmpty || !_scroll.hasClients) return;
    _recordPosition();
    _markUnreadCrossings();
    _prevTitleY.clear();
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
      final visible = _visibleItems();
      final idx = _edgeEntryIndex(bottom: false);
      final at = (idx != null && idx >= 0 && idx < visible.length)
          ? visible[idx]
          : null;
      if (at != null && at.id == wantTopId) {
        _finishRestore(); // ✓ 落点正确
        return;
      }
      if (attempt >= _restoreAttempts) {
        _finishRestore(); // 放弃纠偏，保持现状（差几条不影响用）
        return;
      }
      final k = visible.indexWhere((s) => s.id == wantTopId);
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
    // 只把真实落点写回内存；**还原不判定未读**（规则第 5 条），
    // 所以这里不调 `_onScrollEnd`（那会做穿越采样）。
    _recordPosition();
    _prevTitleY.clear();
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
              itemCount: visible.length + 1,
              itemBuilder: (context, i) {
                if (i == visible.length) {
                  return FooterHint(loading: _loading, hasMore: _hasMore);
                }
                final s = visible[i];
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `unread: true` 才参与绿点（只有时间线传）；
                    // 卡片自己监听 UnreadStore，未读变已读时刷新绿点。
                    StatusCard(
                      status: s,
                      unread: UnreadStore.instance.contains(s.id),
                      onTap: () {
                        // 点开详情即视为已读（规则第 6 条）
                        UnreadStore.instance.markRead(s.id);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DetailPage(mid: s.id),
                          ),
                        );
                      },
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
