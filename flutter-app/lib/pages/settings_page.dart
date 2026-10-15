import 'package:flutter/material.dart';

import '../data/cache.dart';
import '../session.dart';

/// 设置页（入口在「我的」页）。
///
/// 「关闭广告」对应原 Compose 版信息流里的 `hideAds` 过滤项 ——
/// 那边是塞在信息流的一个筛选弹层里，这里提升成正式的设置入口（用户要求）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: AnimatedBuilder(
        animation: Settings.instance,
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
