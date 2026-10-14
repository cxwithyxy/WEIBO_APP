import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'session.dart';
import 'src/rust/api/weibo.dart' as api;
import 'src/rust/frb_generated.dart';

/// 微博客户端（Rust core + Flutter UI）。
///
/// 启动顺序很关键：
///   1. `RustLib.init()`   —— 加载 Rust 动态库 + 初始化 FRB
///   2. `initClient()`     —— 构造全局 WeiboClient（内部建 ReqwestEngine，装 TLS）
///   3. `Settings.load()`  —— 读外观设置
///   4. `Session.bootstrap()` —— 从沙箱里的 cookie 文件恢复登录态
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await api.initClient();
  await Settings.instance.load();
  await Session.instance.bootstrap();

  // 图片内存缓存上限。
  //
  // 关于「列表是不是虚拟列表」（用户提问）：
  //   `ListView.builder` / `ListView.separated` 本身就是**懒加载**的 ——
  //   只构建视口内（± cacheExtent，默认 250px）的元素并复用 element，
  //   所以 CPU/构建开销天然被视口大小限制，与列表总长度无关。
  //   真正会随滚动持续累积的是**图片内存缓存**，所以在这里设个上限。
  //   默认是 1000 张 / 100MB；feed 场景下调成 200 张更省内存。
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20; // 64MB

  runApp(const WeiboApp());
}

const _seed = Color(0xFFE6162D);

class WeiboApp extends StatelessWidget {
  const WeiboApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 同时监听「登录态」与「外观」两个变更源
    return AnimatedBuilder(
      animation: Listenable.merge([Session.instance, Settings.instance]),
      builder: (context, _) {
        final session = Session.instance;
        return MaterialApp(
          title: '微博 · Rust + Flutter',
          debugShowCheckedModeBanner: false,
          themeMode: Settings.instance.themeMode,
          theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
          darkTheme: ThemeData(
            colorSchemeSeed: _seed,
            brightness: Brightness.dark,
            useMaterial3: true,
          ),
          home: !session.ready
              ? const _Splash()
              : session.loggedIn
                  ? HomePage(onLoggedOut: () {})
                  : LoginPage(onLoggedIn: () {}),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在检查登录状态…', style: TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
