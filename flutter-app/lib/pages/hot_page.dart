import 'package:flutter/material.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';
import 'search_page.dart';

/// 热搜榜（公开接口，不需要登录）。
class HotPage extends StatefulWidget {
  const HotPage({super.key, this.controller});

  /// 外部传入的滚动控制器（供「双击顶部回顶部」使用）
  final ScrollController? controller;

  @override
  State<HotPage> createState() => _HotPageState();
}

class _HotPageState extends State<HotPage> with AutomaticKeepAliveClientMixin {
  List<HotItemDto>? _items;
  Object? _error;
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool get _ownsScroll => widget.controller == null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    if (_ownsScroll) _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final list = await api.hotSearch();
      if (mounted) setState(() => _items = list);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null) return ErrorView(error: _error!, onRetry: _load);
    final items = _items;
    if (items == null) return const Center(child: CircularProgressIndicator());
    if (items.isEmpty) return const EmptyView(text: '暂无热搜');

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        controller: _scroll,
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 12, endIndent: 12),
        itemBuilder: (context, i) {
          final it = items[i];
          return ListTile(
            dense: true,
            leading: SizedBox(
              width: 26,
              child: Text(
                '${i + 1}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: i < 3 ? const Color(0xFFE6162D) : Colors.grey.shade500,
                ),
              ),
            ),
            title: Text(it.word, style: const TextStyle(fontSize: 15)),
            subtitle: it.label.isEmpty ? null : Text(it.label, style: const TextStyle(fontSize: 12)),
            trailing: Text(
              fmtCount(p64Int(it.heat)),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SearchPage(initialQuery: it.word)),
            ),
          );
        },
      ),
    );
  }
}
