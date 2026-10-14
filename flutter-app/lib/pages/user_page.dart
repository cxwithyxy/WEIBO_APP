import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';
import '../widgets/status_card.dart';
import 'detail_page.dart';

/// 用户页（他人主页）：资料 + TA 的微博。
class UserPage extends StatefulWidget {
  const UserPage({super.key, required this.uid});

  final String uid;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> {
  UserDto? _user;
  Object? _profileError;

  final _items = <StatusDto>[];
  final _scroll = ScrollController();
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
      _loadList();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() => _profileError = null);
    try {
      final u = await api.profile(uid: widget.uid);
      if (mounted) setState(() => _user = u);
    } catch (e) {
      if (mounted) setState(() => _profileError = e);
    }
  }

  Future<void> _loadList() async {
    setState(() {
      _loading = true;
      _listError = null;
    });
    try {
      final p = await api.userTimelinePage(uid: widget.uid, page: 1);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(p.statuses);
        _page = 2;
        _hasMore = p.statuses.length >= 20;
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
      final p = await api.userTimelinePage(uid: widget.uid, page: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(p.statuses);
        _page += 1;
        _hasMore = p.statuses.isNotEmpty;
      });
    } catch (_) {
      if (mounted) setState(() => _hasMore = false);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_user?.name ?? '用户'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadProfile();
          await _loadList();
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
    final u = _user;
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
                      'uid ${u?.id ?? widget.uid}',
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
        if (_listError != null && _items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: ErrorView(error: _listError!, onRetry: _loadList),
          ),
        if (_items.isEmpty && !_loading && _listError == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: EmptyView(text: '这个用户还没有微博'),
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
}
