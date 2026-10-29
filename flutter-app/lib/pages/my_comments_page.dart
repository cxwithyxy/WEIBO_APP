import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';
import '../widgets/status_card.dart' show Avatar;
import 'detail_page.dart';

/// 「我的评论」—— 我发出的评论列表（`/ajax/message/myCmt`）。
///
/// 每条显示两块：
///   ① 我写的评论（正文 + 时间 + 点赞数）；
///   ② 被评论的原微博（作者 + 正文摘要），点它进原微博详情。
///
/// 游标翻页：`next_cursor` 为 `null` 表示没有更多；为空表示还没发过评论。
class MyCommentsPage extends StatefulWidget {
  const MyCommentsPage({super.key, this.loader});

  /// 测试注入：默认走真实接口，测试里换成固定数据（不发网络请求）。
  final Future<MyCommentsPageDto> Function(int? cursor)? loader;

  @override
  State<MyCommentsPage> createState() => _MyCommentsPageState();
}

class _MyCommentsPageState extends State<MyCommentsPage> {
  final List<MyCommentDto> _items = [];
  int? _cursor;
  int? _total;
  bool _loading = false;
  bool _hasMore = true;
  Object? _error;
  final _scroll = ScrollController();

  Future<MyCommentsPageDto> _fetch(int? cursor) =>
      widget.loader?.call(cursor) ?? api.myComments(cursor: cursor);

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
    // 距底 400px 内就预取下一页（列表很长时体验更连续）
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
          _items.addAll(page.comments);
        }
        _cursor = page.nextCursor;
        _total = page.total;
        // 游标为 null = 到底了；本页没数据也视为到底（防止死循环拉同一页）
        _hasMore = page.nextCursor != null && page.comments.isNotEmpty;
        _error = null;
      });
      // 内容没铺满一屏时用户没机会「上拉」，主动补下一页，
      // 免得看起来像「就这几条，没了」。
      WidgetsBinding.instance.addPostFrameCallback((_) => _fillViewport());
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 列表内容没铺满视口、且还有下一页时继续拉。
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
        title: Text(_total == null ? '我的评论' : '我的评论 · ${_total!}'),
      ),
      body: Builder(
        builder: (context) {
          if (firstLoad) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_items.isEmpty) {
            if (_error != null) {
              return ErrorView(
                error: _error!,
                onRetry: () => _load(first: true),
              );
            }
            return const Center(
              child: Text('还没有发过评论', style: TextStyle(color: Colors.grey)),
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
                return _MyCommentTile(item: _items[i]);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _footer() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )),
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

/// 一条「我的评论」：上面是我写的，下面是被评论的原微博。
class _MyCommentTile extends StatelessWidget {
  const _MyCommentTile({required this.item});

  final MyCommentDto item;

  @override
  Widget build(BuildContext context) {
    final c = item.comment;
    final root = item.root;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(url: c.user?.avatar ?? '', size: 22),
              const SizedBox(width: 6),
              Text(
                c.user?.name ?? '我',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 8),
              Text(
                c.time,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
              ),
              const Spacer(),
              if (c.likes > 0) ...[
                Icon(Icons.thumb_up_alt_outlined,
                    size: 13, color: Colors.grey.shade600),
                const SizedBox(width: 3),
                Text('${c.likes}',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            c.text,
            style: const TextStyle(fontSize: 15, height: 1.4),
          ),
          if (c.images.isNotEmpty) ...[
            const SizedBox(height: 6),
            ImageGrid(urls: c.images, small: true),
          ],
          if (root != null) ...[
            const SizedBox(height: 8),
            // 原微博：点它进详情页（myCmt 自带原微博对象，不用额外请求）
            InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DetailPage(mid: root.id)),
              ),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white.withValues(alpha: 0.05)
                      : const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.chat_bubble_outline,
                            size: 12, color: Color(0xFF8A8A8A)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '原微博 · ${root.user?.name ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF8A8A8A)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      root.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, height: 1.35),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
