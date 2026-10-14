import 'package:flutter/material.dart';

import 'compose_page.dart';
import 'hot_page.dart';
import 'profile_page.dart';
import 'search_page.dart';
import 'timeline_page.dart';

/// 主框架：底部 5 个 tab + 发微博悬浮按钮。
///
/// tab 顺序与原 Android 版一致：首页 / 关注 / 搜索 / 热搜 / 我的。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onLoggedOut});

  final VoidCallback onLoggedOut;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  static const _titles = ['首页', '关注', '搜索', '热搜', '我的'];

  Future<void> _compose() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const ComposePage()),
    );
    if (ok == true && mounted) {
      // 发完回到首页刷新
      setState(() => _tab = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_tab])),
      body: IndexedStack(
        index: _tab,
        children: [
          const TimelinePage(kind: TimelineKind.home),
          const TimelinePage(kind: TimelineKind.following),
          const SearchPage(embedded: true),
          const HotPage(),
          ProfilePage(onLoggedOut: widget.onLoggedOut),
        ],
      ),
      floatingActionButton: (_tab == 0 || _tab == 1)
          ? FloatingActionButton(
              tooltip: '发微博',
              onPressed: _compose,
              child: const Icon(Icons.edit),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          NavigationDestination(icon: Icon(Icons.people_alt_outlined), selectedIcon: Icon(Icons.people_alt), label: '关注'),
          NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
          NavigationDestination(
              icon: Icon(Icons.local_fire_department_outlined),
              selectedIcon: Icon(Icons.local_fire_department),
              label: '热搜'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}
