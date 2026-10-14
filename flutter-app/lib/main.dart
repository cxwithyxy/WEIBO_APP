import 'package:flutter/material.dart';

import 'src/rust/api/dto.dart';
import 'src/rust/api/error.dart';
import 'src/rust/api/weibo.dart';
import 'src/rust/frb_generated.dart';

/// Phase 1 垂直切片：证明 Rust core + Flutter 这条链路是通的。
///
/// - 「热搜」**不需要登录** —— 保证有一个必定成功的正向用例（冒烟测试）
/// - 「关注」走完整 cookie 登录链路，未登录时会显示可读的错误原因
///
/// 界面刻意保持简单（列表 + 错误展示），重点是**链路**而不是 UI 打磨。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 1) 加载 Rust 动态库并初始化 FRB
  await RustLib.init();
  // 2) 初始化全局客户端（内部构造 ReqwestEngine）
  await initClient();
  runApp(const WeiboApp());
}

class WeiboApp extends StatelessWidget {
  const WeiboApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微博 · Rust + Flutter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFE6162D),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

/// 把异常转成可读文本。
///
/// `WeiboFailure` 是桥接层专门定义的可读错误（见 rust/src/api/error.rs）——
/// 直接从 Rust 抛出，带 `kind` 与 `message`。
String describeError(Object e) {
  if (e is WeiboFailure) {
    return '${e.kind}: ${e.message}';
  }
  return e.toString();
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('微博 · Rust core + Flutter'),
        backgroundColor: const Color(0xFFE6162D),
        foregroundColor: Colors.white,
      ),
      body: IndexedStack(
        index: _tab,
        children: const [HotPage(), FollowingPage()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.local_fire_department), label: '热搜'),
          NavigationDestination(icon: Icon(Icons.people_alt), label: '关注'),
        ],
      ),
    );
  }
}

/// 通用：加载失败时展示可读错误 + 重试按钮。
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.orange),
            const SizedBox(height: 12),
            SelectableText(
              describeError(error),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 热搜

class HotPage extends StatefulWidget {
  const HotPage({super.key});

  @override
  State<HotPage> createState() => _HotPageState();
}

class _HotPageState extends State<HotPage> {
  late Future<List<HotItemDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = hotSearch();
  }

  void _reload() => setState(() => _future = hotSearch());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<HotItemDto>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorView(error: snap.error!, onRetry: _reload);
        }
        final items = snap.data ?? const <HotItemDto>[];
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final it = items[i];
              return ListTile(
                leading: SizedBox(
                  width: 28,
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: i < 3 ? const Color(0xFFE6162D) : Colors.grey,
                    ),
                  ),
                ),
                title: Text(it.word),
                subtitle: it.label.isEmpty ? null : Text(it.label),
                trailing: Text(
                  _formatHeat(it.heat),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 热度数值格式化：123456 → 12.3万
String _formatHeat(Object heat) {
  final n = int.tryParse(heat.toString()) ?? 0;
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return '$n';
}

// ---------------------------------------------------------------- 关注流

class FollowingPage extends StatefulWidget {
  const FollowingPage({super.key});

  @override
  State<FollowingPage> createState() => _FollowingPageState();
}

class _FollowingPageState extends State<FollowingPage> {
  late Future<List<StatusDto>> _future;

  @override
  void initState() {
    super.initState();
    _future = followingTimeline(count: 20);
  }

  void _reload() => setState(() => _future = followingTimeline(count: 20));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StatusDto>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return ErrorView(error: snap.error!, onRetry: _reload);
        }
        final list = snap.data ?? const <StatusDto>[];
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView.builder(
            itemCount: list.length,
            itemBuilder: (context, i) => StatusCard(status: list[i]),
          ),
        );
      },
    );
  }
}

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.status});

  final StatusDto status;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(status.user),
            const SizedBox(height: 8),
            if (status.text.isNotEmpty)
              Text(status.text, style: const TextStyle(fontSize: 15, height: 1.4)),
            if (status.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              _images(status.images),
            ],
            if (status.retweeted != null) ...[
              const SizedBox(height: 8),
              _retweeted(status.retweeted!),
            ],
            const SizedBox(height: 8),
            _footer(status),
          ],
        ),
      ),
    );
  }

  Widget _header(UserDto? user) {
    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: Colors.grey.shade200,
          backgroundImage:
              (user != null && user.avatar.isNotEmpty) ? NetworkImage(user.avatar) : null,
          child: (user == null || user.avatar.isEmpty) ? const Icon(Icons.person, size: 18) : null,
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
                      user?.name ?? '(未知用户)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (user?.verified == true)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.verified, size: 14, color: Colors.orange),
                    ),
                ],
              ),
              Text(
                status.time,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        if (status.isAd)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(3),
            ),
            child: const Text('广告', style: TextStyle(fontSize: 10, color: Colors.grey)),
          ),
      ],
    );
  }

  Widget _images(List<String> urls) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: urls.length > 9 ? 9 : urls.length,
      itemBuilder: (context, i) => Image.network(
        urls[i],
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: Colors.grey.shade200,
          child: const Icon(Icons.broken_image, color: Colors.grey),
        ),
      ),
    );
  }

  Widget _retweeted(StatusDto rt) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '@${rt.user?.name ?? '(未知用户)'}',
            style: const TextStyle(fontSize: 13, color: Color(0xFFE6162D)),
          ),
          if (rt.text.isNotEmpty)
            Text(rt.text, style: const TextStyle(fontSize: 14, height: 1.35)),
          if (rt.images.isNotEmpty) ...[
            const SizedBox(height: 6),
            _images(rt.images),
          ],
        ],
      ),
    );
  }

  Widget _footer(StatusDto s) {
    return Row(
      children: [
        _metric(Icons.repeat, s.reposts),
        const SizedBox(width: 18),
        _metric(Icons.chat_bubble_outline, s.comments),
        const SizedBox(width: 18),
        _metric(Icons.thumb_up_outlined, s.likes),
        const Spacer(),
        if (s.isLongText)
          const Text('长文', style: TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _metric(IconData icon, int n) {
    return Row(
      children: [
        Icon(icon, size: 15, color: Colors.grey.shade600),
        const SizedBox(width: 4),
        Text('$n', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }
}
