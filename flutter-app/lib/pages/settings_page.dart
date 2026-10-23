import 'package:flutter/material.dart';

import '../data/cache.dart';
import '../data/unread.dart';
import '../data/video_cache.dart';
import '../session.dart';
import '../util/backfill_setting.dart';

/// 设置页（入口在「我的」页）。
///
/// 「关闭广告」对应原 Compose 版信息流里的 `hideAds` 过滤项 ——
/// 那边是塞在信息流的一个筛选弹层里，这里提升成正式的设置入口（用户要求）。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 视频缓存占用；null = 还在统计。统计与清空都在 isolate 里做。
  VideoCacheUsage? _videoUsage;
  bool _clearingVideo = false;

  @override
  void initState() {
    super.initState();
    _refreshVideoUsage();
  }

  Future<void> _refreshVideoUsage() async {
    VideoCacheUsage? u;
    try {
      u = await VideoCache.usage();
    } catch (_) {
      u = const VideoCacheUsage(0, 0);
    }
    if (!mounted) return;
    setState(() => _videoUsage = u);
  }

  Future<void> _confirmClearVideo() async {
    if (_clearingVideo) return;
    // 点之前再算一次，对话框里的数字必须是此刻的
    final u = await VideoCache.usage();
    if (!mounted) return;
    if (u.isEmpty) {
      setState(() => _videoUsage = u);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可清除的视频缓存')),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除视频缓存？'),
        content: Text(
          '将删除已缓存的视频文件，共 ${formatCacheBytes(u.bytes)}（${u.files} 个文件）。\n'
          '不会影响信息流缓存、单条微博缓存、登录状态和封面图；'
          '之后再看视频会重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _clearingVideo = true);
    VideoCacheClearResult r;
    try {
      r = await VideoCache.clear();
    } catch (_) {
      r = const VideoCacheClearResult(0, 0, 0);
    }
    // 删完重新统计：被占用删不掉的文件会留在占用里，副标题如实显示
    await _refreshVideoUsage();
    if (!mounted) return;
    setState(() => _clearingVideo = false);

    final msg = r.failed > 0
        ? '已清除 ${formatCacheBytes(r.freedBytes)}，'
            '${r.failed} 个文件正在使用中未能删除'
        : '已清除 ${formatCacheBytes(r.freedBytes)}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String get _videoSubtitle {
    final u = _videoUsage;
    if (u == null) return '正在统计…';
    if (_clearingVideo) return '正在清除…';
    return u.label;
  }

  /// 点「每次刷新最多补拉页数」→ 滑杆对话框。
  ///
  /// 确定才落盘；取消 / 点外部返回 null → 什么都不做。
  Future<void> _pickMaxBackfillPages() async {
    final s = Settings.instance;
    // 对话框内的临时值：拖动只改它，不碰 Settings
    var draft = clampMaxBackfillPages(s.maxBackfillPages);
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('每次刷新最多补拉页数'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                backfillPagesLabel(draft),
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              Slider(
                min: kMinMaxBackfillPages.toDouble(),
                max: kMaxMaxBackfillPages.toDouble(),
                // 步长 5：(120-5)/5 = 23 段
                divisions:
                    (kMaxMaxBackfillPages - kMinMaxBackfillPages) ~/ 5,
                value: draft.toDouble(),
                label: backfillPagesLabel(draft),
                onChanged: (v) => setDialogState(
                  () => draft = clampMaxBackfillPages(v.round()),
                ),
              ),
              Text(
                '下拉刷新时，最多往后翻多少页去补上和旧缓存之间的断档。\n'
                '调大能补更久以前的内容，但一次刷新会更慢（每页约 26 分钟内容）。',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(draft),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await Settings.instance.setMaxBackfillPages(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AnimatedBuilder(
        animation: Listenable.merge([Settings.instance, UnreadStore.instance]),
        builder: (context, _) {
          final s = Settings.instance;
          return ListView(
            children: [
              _section(context, '信息流'),
              SwitchListTile(
                secondary: const Icon(Icons.block_outlined),
                title: const Text('关闭广告'),
                subtitle: const Text('信息流里不显示推广微博'),
                value: s.hideAds,
                onChanged: s.setHideAds,
              ),
              ListTile(
                leading: const Icon(Icons.download_for_offline_outlined),
                title: const Text('每次刷新最多补拉页数'),
                subtitle: Text(backfillPagesLabel(s.maxBackfillPages)),
                onTap: _pickMaxBackfillPages,
              ),
              ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined),
                title: const Text('清除全部未读标记'),
                subtitle: Text(
                  UnreadStore.instance.count > 0
                      ? '当前 ${UnreadStore.instance.count} 条未读'
                      : '当前没有未读标记',
                ),
                onTap: () {
                  final n = UnreadStore.instance.clearAll();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(n > 0 ? '已清除 $n 条未读标记' : '没有未读标记'),
                    ),
                  );
                },
              ),
              const Divider(height: 24),
              _section(context, '缓存'),
              ListTile(
                leading: const Icon(Icons.cleaning_services_outlined),
                title: const Text('清除单条微博缓存'),
                subtitle: const Text('只清「按微博 id」的那部分，不动信息流缓存'),
                onTap: () async {
                  final n = await StatusCache.count();
                  await StatusCache.clearAll();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已清除 $n 条微博缓存')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: const Text('清除视频缓存'),
                subtitle: Text(_videoSubtitle),
                trailing: _clearingVideo
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _clearingVideo ? null : _confirmClearVideo,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
