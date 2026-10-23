import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:weibo_flutter/session.dart';

/// `Settings.maxBackfillPages` 的 SharedPreferences 读写与 clamp。
///
/// 用官方 `SharedPreferences.setMockInitialValues` 模拟磁盘，
/// 验证：无 key 默认 30、set 后可读回、脏值 load 时被 clamp、越界 set 也 clamp。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('没有 key 时读到默认 30', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Settings.instance.load();
    expect(Settings.instance.maxBackfillPages, 30);
  });

  test('set 后内存立即可见，且已按 key 落盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Settings.instance.load();

    await Settings.instance.setMaxBackfillPages(45);

    expect(Settings.instance.maxBackfillPages, 45);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('max_backfill_pages'), 45);
  });

  test('落盘脏值 999 → load 时 clamp 到 120', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'max_backfill_pages': 999,
    });
    await Settings.instance.load();
    expect(Settings.instance.maxBackfillPages, 120);
  });

  test('落盘脏值 -3 → load 时 clamp 到 5', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'max_backfill_pages': -3,
    });
    await Settings.instance.load();
    expect(Settings.instance.maxBackfillPages, 5);
  });

  test('set 越界值会 clamp 后落盘', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Settings.instance.load();

    await Settings.instance.setMaxBackfillPages(1);

    expect(Settings.instance.maxBackfillPages, 5);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getInt('max_backfill_pages'), 5);
  });

  test('重新 load 能读回上次 set 的值（落盘真的生效）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await Settings.instance.load();
    await Settings.instance.setMaxBackfillPages(60);

    await Settings.instance.load();

    expect(Settings.instance.maxBackfillPages, 60);
  });
}
