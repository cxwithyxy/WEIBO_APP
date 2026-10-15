import 'package:flutter/material.dart';

import '../data/cache.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../util/dedup.dart';
import '../widgets/actions.dart';
import '../widgets/common.dart';
import '../widgets/status_card.dart';

/// 微博详情页：**3 个 tab —— 正文 / 评论 / 转发**。
///
/// 结构上刻意保持简单（用户反馈后重构）：
///  - 三个 tab 各自是一个独立可滚动列表，**不做「头部 + 内嵌列表」的嵌套滚动**。
///    早先用 NestedScrollView 把正文当 header、评论/转发当内层列表，
///    内外两层滚动 + 内层 RefreshIndicator 互相打架 →
///    「往下滑之后上不去、反而触发刷新」。
///  - 详情页**不做下拉刷新**（用户要求）：正文不会变，评论/转发靠「滑到底自动加载更多」。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.mid});

  final String mid;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with SingleTickerProviderStateMixin {
  StatusDto? _status;
  Object? _error;

  late final TabController _tabs = TabController(length: 3, vsync: this);

  final _bodyScroll = ScrollController();
  final _commentScroll = ScrollController();
  final _repostScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _bodyScroll.dispose();
    _commentScroll.dispose();
    _repostScroll.dispose();
    super.dispose();
  }

  /// 双击/单击标题 → 当前 tab 回顶部
  void _scrollCurrentToTop() {
    final c = switch (_tabs.index) {
      0 => _bodyScroll,
      1 => _commentScroll,
      _ => _repostScroll,
    };
    if (!c.hasClients) return;
    c.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _load() async {
    setState(() => _error = null);

    // 1) 先用缓存渲染（缓存按**微博 id** 存，命中就是秒开）
    final cached = await StatusCache.load(widget.mid);
    if (cached != null && mounted) {
      try {
        final r = await api.parseStatusRaw(raw: cached);
        if (r.status != null && mounted) setState(() => _status = r.status);
      } catch (_) {
        // 缓存解析失败就丢掉，走网络
      }
    }

    // 2) 再回网络刷新，并把**响应原文**存进缓存
    try {
      final r = await api.statusDetailRaw(mid: widget.mid);
      if (r.status != null && mounted) setState(() => _status = r.status);
      if (r.raw.isNotEmpty) await StatusCache.save(widget.mid, r.raw);
    } catch (e) {
      // 已有缓存时网络失败不覆盖屏幕
      if (mounted && _status == null) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _scrollCurrentToTop,
          onDoubleTap: _scrollCurrentToTop,
          child: const SizedBox(
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('微博正文'),
            ),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '正文'), Tab(text: '评论'), Tab(text: '转发')],
        ),
      ),
      body: _error != null
          ? ErrorView(error: _error!, onRetry: _load)
          : s == null
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _BodyTab(status: s, controller: _bodyScroll),
                    _CommentsTab(
                      mid: widget.mid,
                      initialTotal: s.comments,
                      controller: _commentScroll,
                    ),
                    _RepostsTab(mid: widget.mid, controller: _repostScroll),
                  ],
                ),
    );
  }
}

// ------------------------------------------------------------------ 正文

/// 正文 tab。长文也能正常滚动：整页就是一个 ListView，没有嵌套滚动。
///
/// `expandByDefault: true` —— 用户要求：**详情页正文默认展开全文**，
/// 不用再手动点「展开全文」。
class _BodyTab extends StatelessWidget {
  const _BodyTab({required this.status, this.controller});

  final StatusDto status;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [StatusCard(status: status, expandByDefault: true)],
    );
  }
}

// ------------------------------------------------------------------ 评论

class _CommentsTab extends StatefulWidget {
  const _CommentsTab({
    required this.mid,
    required this.initialTotal,
    this.controller,
  });

  final String mid;
  final int initialTotal;
  final ScrollController? controller;

  @override
  State<_CommentsTab> createState() => _CommentsTabState();
}

class _CommentsTabState extends State<_CommentsTab> with AutomaticKeepAliveClientMixin {
  final _items = <CommentDto>[];

  /// 已出现过的评论 id —— 跨页去重（见 util/dedup.dart）
  final _seen = <String>{};
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;
  int _maxId = 0;
  int? _total;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
        _more();
      }
    });
    _load();
  }

  @override
  void dispose() {
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // flow=1（按时间）才能翻页；flow=0 按热度翻不了页
      final p = await api.commentsPage(mid: widget.mid, count: 20, maxId: 0, flow: 1);
      if (!mounted) return;
      final fresh = dedupById(p.comments, (c) => c.id);
      setState(() {
        _items
          ..clear()
          ..addAll(fresh);
        _seen
          ..clear()
          ..addAll(fresh.map((c) => c.id));
        _maxId = p64Int(p.nextMaxId);
        _total = p.total;
        _hasMore = p.comments.length >= 20;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final p = await api.commentsPage(mid: widget.mid, count: 20, maxId: _maxId, flow: 1);
      if (!mounted) return;
      final fresh = dedupById(p.comments, (c) => c.id, seen: _seen);
      setState(() {
        _items.addAll(fresh);
        _maxId = p64Int(p.nextMaxId);
        _hasMore = p.comments.isNotEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null && _items.isEmpty) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty && _loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const EmptyView(text: '还没有评论', icon: Icons.chat_bubble_outline);
    }
    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              '评论 ${_total ?? widget.initialTotal}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
          );
        }
        if (i == _items.length) return FooterHint(loading: _loading, hasMore: _hasMore);
        final c = _items[i - 1];
        return _CommentTile(
          comment: c,
          onReply: () => showCommentSheet(
            context,
            id: widget.mid,
            subtitle: '回复 @${c.user?.name ?? ''}：${c.text}',
            replyToCid: c.id,
          ),
        );
      },
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, this.onReply});

  final CommentDto comment;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) {
    final u = comment.user;
    return InkWell(
      onTap: onReply,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Avatar(url: u?.avatar ?? '', size: 34),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          u?.name ?? '(未知)',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (comment.isAuthor)
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE6162D).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text('作者',
                              style: TextStyle(fontSize: 10, color: Color(0xFFE6162D))),
                        ),
                      const Spacer(),
                      Text(comment.time,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (comment.replyTo != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? Colors.white10
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '@${comment.replyTo!.user?.name ?? ''}：${comment.replyTo!.text}',
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  SelectableText(comment.text, style: const TextStyle(fontSize: 14.5, height: 1.4)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.thumb_up_outlined, size: 13, color: Colors.grey.shade600),
                      const SizedBox(width: 4),
                      Text('${comment.likes}',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                      if (comment.floor > 0) ...[
                        const SizedBox(width: 12),
                        Text('${comment.floor}楼',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 转发

class _RepostsTab extends StatefulWidget {
  const _RepostsTab({required this.mid, this.controller});

  final String mid;
  final ScrollController? controller;

  @override
  State<_RepostsTab> createState() => _RepostsTabState();
}

class _RepostsTabState extends State<_RepostsTab> with AutomaticKeepAliveClientMixin {
  final _items = <StatusDto>[];

  /// 已出现过的微博 id —— 跨页去重（见 util/dedup.dart）
  final _seen = <String>{};
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
        _more();
      }
    });
    _load();
  }

  @override
  void dispose() {
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await api.reposts(mid: widget.mid, page: 1);
      if (!mounted) return;
      final fresh = dedupById(list, (s) => s.id);
      setState(() {
        _items
          ..clear()
          ..addAll(fresh);
        _seen
          ..clear()
          ..addAll(fresh.map((s) => s.id));
        _page = 2;
        _hasMore = list.length >= 20;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final list = await api.reposts(mid: widget.mid, page: _page);
      if (!mounted) return;
      // 页码翻页在动态转发流上必然有跨页重叠 → 追加前按 id 去重
      final fresh = dedupById(list, (s) => s.id, seen: _seen);
      setState(() {
        _items.addAll(fresh);
        _page += 1;
        _hasMore = list.isNotEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null && _items.isEmpty) return ErrorView(error: _error!, onRetry: _load);
    if (_items.isEmpty && _loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const EmptyView(text: '还没有转发', icon: Icons.repeat);
    }
    return ListView.separated(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _items.length) return FooterHint(loading: _loading, hasMore: _hasMore);
        return StatusCard(status: _items[i], showActions: false);
      },
    );
  }
}
