import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';
import '../widgets/status_card.dart';
import 'detail_page.dart';

/// 搜索微博。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.initialQuery, this.embedded = false, this.controller});

  final String? initialQuery;

  /// 作为主界面 tab 内嵌时为 true：不套 Scaffold，搜索框放内容顶部
  final bool embedded;

  /// 外部传入的滚动控制器（供「双击顶部回顶部」使用）
  final ScrollController? controller;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialQuery ?? '');
  final _items = <StatusDto>[];
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  bool _searched = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients &&
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
        _more();
      }
    });
    if ((widget.initialQuery ?? '').isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final list = await api.search(q: q, count: 20, page: 1);
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
    if (_loading || !_hasMore || !_searched) return;
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() => _loading = true);
    try {
      final list = await api.search(q: q, count: 20, page: _page);
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

  Widget _searchBar({bool autofocus = false}) {
    return TextField(
      controller: _ctrl,
      autofocus: autofocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      decoration: const InputDecoration(
        hintText: '搜索微博',
        border: InputBorder.none,
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(child: _searchBar()),
                TextButton(onPressed: _search, child: const Text('搜索')),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: _searchBar(autofocus: widget.initialQuery == null),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: _search),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) return ErrorView(error: _error!, onRetry: _search);
    if (!_searched) {
      return const EmptyView(text: '输入关键词后回车搜索', icon: Icons.search);
    }
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return const EmptyView(text: '没有搜到相关微博', icon: Icons.search_off);
    }
    return ListView.separated(
      controller: _scroll,
      itemCount: _items.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _items.length) return FooterHint(loading: _loading, hasMore: _hasMore);
        final s = _items[i];
        return StatusCard(
          status: s,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => DetailPage(mid: s.id)),
          ),
        );
      },
    );
  }
}
