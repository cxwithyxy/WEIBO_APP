import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../pages/user_page.dart';
import 'actions.dart';
import 'common.dart';

/// 微博卡片。
///
/// 关于「点赞」：这里自己持有乐观状态（先 +1，失败回滚）—— 对应原 Android 版
/// 「点赞计数乐观 +1」的行为。列表刷新时用新的 `status` 覆盖即可。
class StatusCard extends StatefulWidget {
  const StatusCard({
    super.key,
    required this.status,
    this.onTap,
    this.showActions = true,
    this.expandByDefault = false,
  });

  final StatusDto status;
  final VoidCallback? onTap;
  final bool showActions;

  /// 正文**默认展开全文**（详情页「正文」tab 用）：
  /// 长文会自动把全文拉下来直接展示，不再显示「展开全文」。
  final bool expandByDefault;

  @override
  State<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<StatusCard> {
  bool _liked = false;
  late int _likes = widget.status.likes;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant StatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表刷新后，用服务端数据重置（但保留已点赞状态）
    if (oldWidget.status.id != widget.status.id) {
      _likes = widget.status.likes;
      _liked = false;
    }
  }

  Future<void> _toggleLike() async {
    if (_busy) return;
    final wantLike = !_liked;
    setState(() {
      _busy = true;
      _liked = wantLike;
      _likes += wantLike ? 1 : -1; // 乐观更新
    });
    try {
      if (wantLike) {
        await api.setLike(id: widget.status.id);
      } else {
        await api.cancelLike(id: widget.status.id);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(wantLike ? '已点赞' : '已取消赞'),
          duration: const Duration(seconds: 1),
        ));
    } catch (e) {
      // 回滚
      if (!mounted) return;
      setState(() {
        _liked = !wantLike;
        _likes += wantLike ? -1 : 1;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('操作失败：${describeError(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _repost() => showRepostSheet(context, widget.status);

  void _comment() => showCommentSheet(
        context,
        id: widget.status.id,
        subtitle: '评论 @${widget.status.user?.name ?? ''}',
      );

  @override
  Widget build(BuildContext context) {
    final s = widget.status;
    return InkWell(
      onTap: widget.onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(status: s),
            const SizedBox(height: 8),
            if (s.text.isNotEmpty)
              _BodyText(status: s, expandByDefault: widget.expandByDefault),
            if (s.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              ImageGrid(urls: s.images),
            ],
            if (s.retweeted != null) ...[
              const SizedBox(height: 8),
              _RetweetBox(status: s.retweeted!),
            ],
            const SizedBox(height: 6),
            if (widget.showActions) _actions(s) else _metrics(s),
          ],
        ),
      ),
    );
  }

  Widget _actions(StatusDto s) {
    return Row(
      children: [
        _actionBtn(
          icon: Icons.repeat,
          label: fmtCount(s.reposts),
          onTap: _repost,
        ),
        Expanded(
          child: _actionBtn(
            icon: Icons.chat_bubble_outline,
            label: fmtCount(s.comments),
            onTap: _comment,
          ),
        ),
        Expanded(
          child: _actionBtn(
            icon: _liked ? Icons.thumb_up : Icons.thumb_up_outlined,
            label: fmtCount(_likes),
            color: _liked ? const Color(0xFFE6162D) : null,
            onTap: _toggleLike,
          ),
        ),
        if (s.isLongText)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('长文', style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _metrics(StatusDto s) {
    return Row(
      children: [
        _metric(Icons.repeat, fmtCount(s.reposts)),
        const SizedBox(width: 20),
        _metric(Icons.chat_bubble_outline, fmtCount(s.comments)),
        const SizedBox(width: 20),
        _metric(Icons.thumb_up_outlined, fmtCount(s.likes)),
      ],
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: color ?? Colors.grey.shade600),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(fontSize: 12.5, color: color ?? Colors.grey.shade600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metric(IconData icon, String n) {
    return Row(
      children: [
        Icon(icon, size: 15, color: Colors.grey.shade600),
        const SizedBox(width: 4),
        Text(n, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }
}

// ------------------------------------------------------------------ 头部

class _Header extends StatelessWidget {
  const _Header({required this.status});

  final StatusDto status;

  @override
  Widget build(BuildContext context) {
    final u = status.user;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 点头像 → 该用户的主页。
        // 原 Compose 版有这个功能，移植到 Flutter 时漏了（UserPage 写好了但没人调用）。
        GestureDetector(
          onTap: (u == null || u.id.isEmpty)
              ? null
              : () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => UserPage(uid: u.id)),
                  ),
          child: Avatar(url: u?.avatar ?? '', size: 40),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      u?.name ?? '(未知用户)',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (u?.verified == true)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.verified, size: 14, color: Colors.orange),
                    ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                status.source.isEmpty ? status.time : '${status.time} · ${status.source}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (status.isAd)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text('广告', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 正文

class _BodyText extends StatefulWidget {
  const _BodyText({required this.status, this.expandByDefault = false});

  final StatusDto status;
  final bool expandByDefault;

  @override
  State<_BodyText> createState() => _BodyTextState();
}

class _BodyTextState extends State<_BodyText> {
  String? _full;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _maybeAutoExpand();
  }

  @override
  void didUpdateWidget(_BodyText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status.id != widget.status.id) {
      _full = null;
      _maybeAutoExpand();
    }
  }

  /// 详情页要求「正文默认展开全文」：长文自动拉全文（不用手动点）
  void _maybeAutoExpand() {
    if (!widget.expandByDefault) return;
    if (!widget.status.isLongText || _full != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _full == null && !_loading) _loadFull();
    });
  }

  Future<void> _loadFull() async {
    setState(() => _loading = true);
    try {
      final t = await api.longText(id: widget.status.id);
      if (!mounted) return;
      setState(() => _full = t ?? widget.status.text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('长文加载失败：${describeError(e)}')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _full ?? widget.status.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 用 Text 而不是 SelectableText：
        // SelectableText 会**吞掉单击**，导致卡片正文区域点不进详情页
        // （用户反馈："要点击用户名附近才能进详情页"，根因就是这里）。
        // 需要选择/复制就去详情页 —— 那边整体包在 SelectionArea 里。
        Text(text, style: const TextStyle(fontSize: 15.5, height: 1.45)),
        // 默认展开模式下不再给「展开全文」按钮（已在自动拉取）
        if (!widget.expandByDefault && widget.status.isLongText && _full == null)
          GestureDetector(
            onTap: _loading ? null : _loadFull,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _loading ? '加载中…' : '展开全文',
                style: const TextStyle(fontSize: 13.5, color: Color(0xFFE6162D)),
              ),
            ),
          ),
        if (widget.expandByDefault && widget.status.isLongText && _loading)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text('正在展开全文…',
                style: TextStyle(fontSize: 12.5, color: Colors.grey)),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 转发块

class _RetweetBox extends StatelessWidget {
  const _RetweetBox({required this.status});

  final StatusDto status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white10
            : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${status.user?.name ?? '(未知用户)'}',
            style: const TextStyle(fontSize: 13, color: Color(0xFFE6162D)),
          ),
          if (status.text.isNotEmpty) ...[
            const SizedBox(height: 2),
            SelectableText(status.text, style: const TextStyle(fontSize: 14.5, height: 1.4)),
          ],
          if (status.images.isNotEmpty) ...[
            const SizedBox(height: 6),
            ImageGrid(urls: status.images, small: true),
          ],
        ],
      ),
    );
  }
}

/// 头像（带磁盘缓存 + 兜底占位）
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.url, this.size = 40});

  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url.isEmpty
            ? Container(
                color: Colors.grey.shade300,
                child: Icon(Icons.person, size: size * 0.6, color: Colors.grey.shade600),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => Container(color: Colors.grey.shade200),
                errorWidget: (_, _, _) => Container(
                  color: Colors.grey.shade300,
                  child: Icon(Icons.person, size: size * 0.6, color: Colors.grey.shade600),
                ),
              ),
      ),
    );
  }
}
