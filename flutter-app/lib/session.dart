import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/rust/api/weibo.dart' as api;

/// 会话状态。
///
/// cookie 由 Rust core 在内存里维护，这里只负责：
///  - 找到可写的 cookie 文件路径（沙箱内），启动时 `restore`、登录后 `save`
///  - 把登录态/uid 通知给 UI
class Session extends ChangeNotifier {
  Session._();
  static final Session instance = Session._();

  bool _loggedIn = false;
  String? _uid;
  bool _ready = false;

  bool get loggedIn => _loggedIn;
  String? get uid => _uid;

  /// 是否已完成启动检查（UI 用它决定显示启动页还是主界面）
  bool get ready => _ready;

  File? _cookieFile;

  Future<File> _cookieFileHandle() async {
    final cached = _cookieFile;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/cookies.tsv');
    _cookieFile = f;
    return f;
  }

  /// App 启动时调用：尝试从磁盘恢复登录态。
  Future<void> bootstrap() async {
    try {
      final f = await _cookieFileHandle();
      if (await f.exists()) {
        final ok = await api.restore(cookieFile: f.path);
        if (ok) {
          _loggedIn = await api.isLoggedIn();
          _uid = await api.uid();
        }
      }
    } catch (_) {
      // 恢复失败一律按「未登录」处理，不阻塞启动
      _loggedIn = false;
      _uid = null;
    }
    _ready = true;
    notifyListeners();
  }

  /// 登录成功后调用：把 cookie 落盘，并刷新状态。
  Future<void> onLoggedIn() async {
    final f = await _cookieFileHandle();
    await api.save(cookieFile: f.path);
    _loggedIn = await api.isLoggedIn();
    _uid = await api.uid();
    notifyListeners();
  }

  /// 退出登录：删掉 cookie 文件。
  ///
  /// ⚠️ 已知限制：Rust 侧内存里的 cookie 罐**不会**被清掉（core 没暴露清空接口），
  /// 所以要彻底生效需要重启 App。这里如实把登录态置为 false，
  /// 让界面回到登录页（与原 Android 版行为一致）。
  Future<void> logout() async {
    final f = await _cookieFileHandle();
    if (await f.exists()) {
      await f.delete();
    }
    _loggedIn = false;
    _uid = null;
    notifyListeners();
  }
}

/// 外观设置（跟随系统 / 浅色 / 深色），持久化到 SharedPreferences。
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings instance = Settings._();

  static const _kTheme = 'theme_mode';

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  Future<void> load() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(_kTheme);
    _themeMode = switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTheme, switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    });
  }
}
