import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import 'common.dart';

/// 转发弹层（内容可留空，留空时后端用「转发微博」占位）。
Future<bool> showRepostSheet(BuildContext context, StatusDto status) async {
  final ctrl = TextEditingController();
  var busy = false;

  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('转发', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '@${status.user?.name ?? ''}：${status.text}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: ctrl,
                maxLines: 4,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '说点什么（可留空）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          setSheet(() => busy = true);
                          try {
                            await api.repost(
                              id: status.id,
                              text: ctrl.text,
                              alsoComment: false,
                              picId: '',
                            );
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                          } catch (e) {
                            if (ctx.mounted) {
                              Navigator.of(ctx).pop(false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('转发失败：${describeError(e)}')),
                              );
                            }
                          }
                        },
                  child: Text(busy ? '发送中…' : '转发'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已转发'), duration: Duration(seconds: 1)));
  }
  return ok == true;
}

/// 评论弹层。`replyToCid` 非空时为回复某条评论。
Future<bool> showCommentSheet(
  BuildContext context, {
  required String id,
  String subtitle = '',
  String? replyToCid,
}) async {
  final ctrl = TextEditingController();
  var busy = false;

  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                replyToCid == null ? '评论' : '回复',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: subtitle.isEmpty ? null : Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: ctrl,
                maxLines: 4,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '说点什么…',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : () async {
                          final text = ctrl.text.trim();
                          if (text.isEmpty) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              const SnackBar(content: Text('评论内容不能为空')),
                            );
                            return;
                          }
                          setSheet(() => busy = true);
                          try {
                            await api.comment(
                              id: id,
                              text: text,
                              replyToCid: replyToCid,
                              alsoRepost: false,
                              picId: '',
                            );
                            if (ctx.mounted) Navigator.of(ctx).pop(true);
                          } catch (e) {
                            if (ctx.mounted) {
                              Navigator.of(ctx).pop(false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('评论失败：${describeError(e)}')),
                              );
                            }
                          }
                        },
                  child: Text(busy ? '发送中…' : '评论'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (ok == true && context.mounted) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('评论成功'), duration: Duration(seconds: 1)));
  }
  return ok == true;
}
