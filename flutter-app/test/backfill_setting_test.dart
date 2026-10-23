import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/backfill_setting.dart';

/// 「每次刷新最多补拉页数」设置项的纯逻辑：边界 clamp、26 分钟/页换算、文案。
void main() {
  group('clampMaxBackfillPages —— 脏数据进不来', () {
    test('下界 5：0 / 4 / 负数都收到 5', () {
      expect(clampMaxBackfillPages(0), 5);
      expect(clampMaxBackfillPages(4), 5);
      expect(clampMaxBackfillPages(-1), 5);
      expect(clampMaxBackfillPages(-999), 5);
    });

    test('上界 120：121 / 999 都收到 120', () {
      expect(clampMaxBackfillPages(121), 120);
      expect(clampMaxBackfillPages(999), 120);
    });

    test('范围内原样保留（含两个端点）', () {
      expect(clampMaxBackfillPages(5), 5);
      expect(clampMaxBackfillPages(30), 30);
      expect(clampMaxBackfillPages(60), 60);
      expect(clampMaxBackfillPages(120), 120);
    });
  });

  group('常量', () {
    test('默认 30、范围 5..120、26 分钟/页', () {
      expect(kDefaultMaxBackfillPages, 30);
      expect(kMinMaxBackfillPages, 5);
      expect(kMaxMaxBackfillPages, 120);
      expect(kMinutesPerPage, 26);
    });
  });

  group('backfillApproxHours —— 26 分钟/页换算', () {
    test('30 → 13h，10 → 4h，120 → 52h', () {
      expect(backfillApproxHours(30), 13); // 30*26/60 = 13.0
      expect(backfillApproxHours(10), 4); //  10*26/60 = 4.33 → 4
      expect(backfillApproxHours(120), 52); // 120*26/60 = 52.0
    });

    test('越界先 clamp 再算：0 → 5 页 ≈ 2h', () {
      expect(backfillApproxHours(0), 2); // 5*26/60 = 2.17 → 2
      expect(backfillApproxHours(999), 52);
    });
  });

  group('backfillPagesLabel —— 设置页副标题文案', () {
    test('默认 30 → 「30 页 · 约 13 小时」', () {
      expect(backfillPagesLabel(30), '30 页 · 约 13 小时');
    });

    test('cx 最初提的 10 页 → 「10 页 · 约 4 小时」', () {
      expect(backfillPagesLabel(10), '10 页 · 约 4 小时');
    });

    test('上界 120 → 「120 页 · 约 52 小时」', () {
      expect(backfillPagesLabel(120), '120 页 · 约 52 小时');
    });

    test('脏值 clamp 后文案仍合法', () {
      expect(backfillPagesLabel(0), '5 页 · 约 2 小时');
      expect(backfillPagesLabel(999), '120 页 · 约 52 小时');
    });
  });
}
