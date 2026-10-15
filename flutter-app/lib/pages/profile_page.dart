import 'package:flutter/material.dart';

import '../session.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';
import '../widgets/status_card.dart';
import 'detail_page.dart';
import 'compose_page.dart';
import 'settings_page.dart';

/// 「我的」页：个人资料 + 我的微博 + 发微博 + 外观设置 + 退出登录。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.onLoggedOut, this.controller});

  final VoidCallback onLoggedOut;

  /// 外部传入的滚动控制器（供「双击顶部回顶部」使用）
  final ScrollController? controller;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  UserDto? _me;
  Object? _profileError;

  final _items = <StatusDto>[];
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  Object? _listError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
        _more();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadProfile();
      _loadBlog();
    });
  }

  @override
  void dispose() {
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() => _profileError = null);
    try {
      final u = await api.profile(uid: null);
      if (mounted) setState(() => _me = u);
    } catch (e) {
      if (mounted) setState(() => _profileError = e);
    }
  }

  Future<void> _loadBlog() async {
    setState(() {
      _loading = true;
      _listError = null;
    });
    try {
      final list = await api.myBlog(uid: null, page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
        _page = 2;
        _hasMore = list.length >= 20;
      });
    } catch (e) {
      if (mounted) setState(() => _listError = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final list = await api.myBlog(uid: null, page: _page);
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

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出'),
        content: const Text('确定要退出微博客户端吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok != true) return;
    await Session.instance.logout();
    widget.onLoggedOut();
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadProfile();
        await _loadBlog();
      },
      child: ListView.builder(
        controller: _scroll,
        itemCount: _items.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) return _header();
          final idx = i - 1;
          if (idx == _items.length) return FooterHint(loading: _loading, hasMore: _hasMore);
          final s = _items[idx];
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

  Widget _header() {
    if (_profileError != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: ErrorView(error: _profileError!, onRetry: _loadProfile),
      );
    }
    final u = _me;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Avatar(url: u?.avatar ?? '', size: 56),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            u?.name ?? '加载中…',
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (u?.verified == true)
                          const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.verified, size: 15, color: Colors.orange),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'uid ${u?.id ?? Session.instance.uid ?? '-'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    if ((u?.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        u!.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (u != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _stat('微博', p64Int(u.statuses)),
                const SizedBox(width: 20),
                _stat('关注', p64Int(u.friends)),
                const SizedBox(width: 20),
                _stat('粉丝', p64Int(u.followers)),
              ],
            ),
          ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        // 发微博不常用 → 从悬浮按钮移到「我的」页（用户反馈）
        ListTile(
          leading: const Icon(Icons.edit_outlined),
          title: const Text('发微博'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ComposePage()),
          ),
        ),
        _appearance(),
        ListTile(
          leading: const Icon(Icons.settings_outlined),
          title: const Text('设置'),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsPage()),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('退出登录'),
          onTap: _confirmLogout,
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              const Text('我的微博', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const SizedBox(width: 6),
              Text('${_items.length}', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ),
        ),
        if (_listError != null && _items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: ErrorView(error: _listError!, onRetry: _loadBlog),
          ),
        if (_items.isEmpty && !_loading && _listError == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: EmptyView(text: '还没有发过微博'),
          ),
      ],
    );
  }

  Widget _stat(String label, int n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$n', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        Text(label, style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
      ],
    );
  }

  Widget _appearance() {
    return AnimatedBuilder(
      animation: Settings.instance,
      builder: (context, _) {
        final mode = Settings.instance.themeMode;
        return ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('外观'),
          trailing: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
              ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
              ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
            ],
            selected: {mode},
            onSelectionChanged: (s) => Settings.instance.setThemeMode(s.first),
            showSelectedIcon: false,
          ),
        );
      },
    );
  }
}
