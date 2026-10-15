import 'package:flutter/material.dart';

import 'hot_page.dart';
import 'profile_page.dart';
import 'search_page.dart';
import 'timeline_page.dart';

/// 主框架：底部 5 个 tab。
///
/// 两个改动来自用户反馈：
///  1. **「发微博」从悬浮按钮移到「我的」页** —— 不常用的操作不该占着悬浮位。
///  2. **双击顶部回顶部** —— 对齐原 Compose 版 `MainTabs` 的行为
///     （原版是在标题上挂 `detectTapGestures(onDoubleTap = { scrollCurrentToTop() })`），
///     我第一版漏移植了。这里每个 tab 各持一个 `ScrollController`，
///     双击标题栏即让当前 tab 的列表滚回顶部。
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onLoggedOut});

  final VoidCallback onLoggedOut;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  // 用户反馈：首页原先落的是「推荐流」，他觉得没必要，希望首页直接就是关注流。
  // 于是去掉「推荐」，不再单设「关注」tab —— 首页即关注。5 个 tab → 4 个。
  static const _titles = ['首页', '搜索', '热搜', '我的'];

  /// 每个 tab 一个控制器，供「双击顶部回顶部」使用。
  /// 传下去的控制器由页面使用、由这里释放（页面不会重复 dispose）。
  final _controllers = List<ScrollController>.generate(4, (_) => ScrollController());

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  void _scrollCurrentToTop() {
    final c = _controllers[_tab];
    if (!c.hasClients) return;
    c.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // 让标题撑满 → 双击标题栏任意位置都能触发
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 单击 / 双击都回顶部：
          //  · 双击对齐原 Compose 版 MainTabs 的行为
          //  · 单击是微信那种常见手感，也更稳（双击对时序敏感）
          onTap: _scrollCurrentToTop,
          onDoubleTap: _scrollCurrentToTop,
          child: SizedBox(
            width: double.infinity,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_titles[_tab]),
            ),
          ),
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          TimelinePage(kind: TimelineKind.following, controller: _controllers[0]),
          SearchPage(embedded: true, controller: _controllers[1]),
          HotPage(controller: _controllers[2]),
          ProfilePage(onLoggedOut: widget.onLoggedOut, controller: _controllers[3]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: '首页'),
          NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
          NavigationDestination(
              icon: Icon(Icons.local_fire_department_outlined),
              selectedIcon: Icon(Icons.local_fire_department),
              label: '热搜'),
          NavigationDestination(
              icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: '我的'),
        ],
      ),
    );
  }
}
