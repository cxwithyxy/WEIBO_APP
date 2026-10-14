import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/actions.dart';
import '../widgets/common.dart';
import '../widgets/status_card.dart';

/// 微博详情页：正文 + 评论 + 转发。
class DetailPage extends StatefulWidget {
  const DetailPage({super.key, required this.mid});

  final String mid;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  StatusDto? _status;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final s = await api.statusDetail(mid: widget.mid);
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('微博正文'),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          bottom: const TabBar(
            tabs: [Tab(text: '评论'), Tab(text: '转发')],
          ),
        ),
        body: Column(
          children: [
            if (_error != null)
              Expanded(child: ErrorView(error: _error!, onRetry: _load))
            else if (s == null)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else ...[
              StatusCard(status: s, showActions: false),
              const Divider(height: 1),
              Expanded(
                child: TabBarView(
                  children: [
                    _CommentsTab(mid: widget.mid, initialTotal: s.comments),
                    _RepostsTab(mid: widget.mid),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 评论

class _CommentsTab extends StatefulWidget {
  const _CommentsTab({required this.mid, required this.initialTotal});

  final String mid;
  final int initialTotal;

  @override
  State<_CommentsTab> createState() => _CommentsTabState();
}

class _CommentsTabState extends State<_CommentsTab> with AutomaticKeepAliveClientMixin {
  final _items = <CommentDto>[];
  final _scroll = ScrollController();
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
    _scroll.dispose();
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
      setState(() {
        _items
          ..clear()
          ..addAll(p.comments);
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
      setState(() {
        _items.addAll(p.comments);
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
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [SizedBox(height: 120), EmptyView(text: '还没有评论', icon: Icons.chat_bubble_outline)],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        controller: _scroll,
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
          final c = _items[i - 1 - 0];
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
      ),
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
                        color: Colors.grey.shade100,
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
  const _RepostsTab({required this.mid});

  final String mid;

  @override
  State<_RepostsTab> createState() => _RepostsTabState();
}

class _RepostsTabState extends State<_RepostsTab> with AutomaticKeepAliveClientMixin {
  final _items = <StatusDto>[];
  final _scroll = ScrollController();
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
    _scroll.dispose();
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
      setState(() {
        _items
          ..clear()
          ..addAll(list);
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
      setState(() {
        _items.addAll(list);
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
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: const [SizedBox(height: 120), EmptyView(text: '还没有转发', icon: Icons.repeat)],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        controller: _scroll,
        itemCount: _items.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          if (i == _items.length) return FooterHint(loading: _loading, hasMore: _hasMore);
          return StatusCard(status: _items[i], showActions: false);
        },
      ),
    );
  }
}
