import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/actions.dart';
import '../widgets/common.dart';
import '../widgets/status_card.dart' show Avatar;
import 'detail_page.dart';

/// 「回复我的评论」—— 谁回了我发出的评论（`/ajax/message/cmt`）。
///
/// 每条显示：
///   ① TA 的回复（回复者 + 时间 + 正文）；
///   ② 我原来那条评论（引用块，方便看上下文）；
///   ③ 原微博（点进详情）；
///   ④ 「回复 TA」—— 复用列表页同一个 `showCommentSheet`，`replyToCid` 传这条回复的 id。
///
/// 注意：这个端点每页条数**不固定**（实测 2/5/1 条），所以判断「还有下一页」
/// 只看 `nextCursor` 是否为空，绝不能用「本页不满 20 条就到头」。
class RepliesPage extends StatefulWidget {
  const RepliesPage({super.key, this.loader});

  /// 测试注入；默认走真实接口。
  final Future<MyCommentsPageDto> Function(int? cursor)? loader;

  @override
  State<RepliesPage> createState() => _RepliesPageState();
}

class _RepliesPageState extends State<RepliesPage> {
  final List<MyCommentDto> _items = [];
  int? _cursor;
  int? _total;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  final _scroll = ScrollController();

  Future<MyCommentsPageDto> _fetch(int? cursor) =>
      widget.loader?.call(cursor) ?? api.receivedComments(cursor: cursor);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(first: true));
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 400) {
      _load(first: false);
    }
  }

  Future<void> _load({required bool first}) async {
    if (_loading) return;
    if (!first && !_hasMore) return;
    setState(() {
      _loading = true;
      if (first) _error = null;
    });
    try {
      final page = await _fetch(first ? null : _cursor);
      if (!mounted) return;
      setState(() {
        if (first) {
          _items
            ..clear()
            ..addAll(page.comments);
        } else {
          // 去重：游标翻页偶有重叠（服务端游标是「时间点」语义）
          final seen = _items.map((e) => e.comment.id).toSet();
          _items.addAll(page.comments.where((e) => !seen.contains(e.comment.id)));
        }
        _cursor = page.nextCursor;
        _total = page.total;
        _hasMore = page.nextCursor != null && page.comments.isNotEmpty;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 内容没铺满一屏时主动补拉（这个端点一页可能只有 1 条）。
  void _fillViewport() {
    if (!mounted || _loading || !_hasMore) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.maxScrollExtent <= 0) _load(first: false);
  }

  @override
  Widget build(BuildContext context) {
    final firstLoad = _items.isEmpty && _loading;
    return Scaffold(
      appBar: AppBar(
        title: Text(_total == null ? '回复我的评论' : '回复我的评论 · ${_total!}'),
      ),
      body: Builder(
        builder: (context) {
          if (firstLoad) return const Center(child: CircularProgressIndicator());
          if (_items.isEmpty) {
            if (_error != null) {
              return ErrorView(error: _error!, onRetry: () => _load(first: true));
            }
            return const Center(
              child: Text('还没有人回复你的评论', style: TextStyle(color: Colors.grey)),
            );
          }
          return RefreshIndicator(
            onRefresh: () => _load(first: true),
            child: ListView.separated(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _items.length + 1,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                if (i == _items.length) return _footer();
                return _ReplyTile(
                  item: _items[i],
                  onReply: () => _replyTo(context, _items[i]),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// 回复 TA：`replyToCid` 用**这条回复**的 id，微博 id 用原微博的 id。
  Future<void> _replyTo(BuildContext context, MyCommentDto item) async {
    final root = item.root;
    if (root == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条缺少原微博，无法回复')),
      );
      return;
    }
    final c = item.comment;
    await showCommentSheet(
      context,
      id: root.id,
      subtitle: '回复 @${c.user?.name ?? ''}：${c.text}',
      replyToCid: c.id,
    );
  }

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Center(
          child: TextButton(
            onPressed: () => _load(first: false),
            child: const Text('加载失败，点此重试'),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: Text(
          _hasMore ? '' : '没有更多了',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
      ),
    );
  }
}

/// 去掉回复正文开头的「回复@某某:」——
/// 这一页本来就是「回复我」的列表，前缀和上面的「回复者」重复，读起来更干净。
/// 只去掉**第一处**且必须出现在开头，正文中间出现的「回复@」不动。
String stripReplyPrefix(String text) {
  final m = RegExp(r'^回复\s*@[^:：]{1,30}[:：]\s*').firstMatch(text);
  return m == null ? text : text.substring(m.end);
}

class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.item, this.onReply});

  final MyCommentDto item;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) {
    final c = item.comment;
    final mine = c.replyTo; // 我原来那条评论
    final root = item.root;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final quoteBg = dark ? Colors.white.withValues(alpha: 0.05) : const Color(0xFFF5F5F5);

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ① 谁回复的
          Row(
            children: [
              Avatar(url: c.user?.avatar ?? '', size: 22),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  c.user?.name ?? '?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                c.time,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
              ),
              const Spacer(),
              Text('回复我', style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 6),
          // ② TA 说的话
          Text(
            stripReplyPrefix(c.text),
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
          if (c.images.isNotEmpty) ...[
            const SizedBox(height: 6),
            ImageGrid(urls: c.images, small: true),
          ],
          // ③ 我当年那条
          if (mine != null) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
              decoration: BoxDecoration(
                color: quoteBg,
                borderRadius: BorderRadius.circular(6),
                border: Border(left: BorderSide(color: Colors.green.shade600, width: 3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('我原来：',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                  const SizedBox(height: 2),
                  Text(
                    mine.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
          // ④ 原微博（点进详情）
          if (root != null) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailPage(mid: root.id)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.article_outlined, size: 12, color: Color(0xFF8A8A8A)),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '原微博 · ${root.user?.name ?? ''}：${root.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF8A8A8A)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          // ⑤ 回复 TA
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onReply,
              icon: const Icon(Icons.reply, size: 16),
              label: const Text('回复 TA', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
