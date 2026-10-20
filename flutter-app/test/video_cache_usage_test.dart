import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/video_cache.dart';

void main() {
  group('formatCacheBytes', () {
    test('0 / 负数 → 0 B', () {
      expect(formatCacheBytes(0), '0 B');
      expect(formatCacheBytes(-5), '0 B');
    });

    test('不到 1KB 给整数字节，其余保留 1 位小数', () {
      expect(formatCacheBytes(1), '1 B');
      expect(formatCacheBytes(1023), '1023 B');
      expect(formatCacheBytes(1024), '1.0 KB');
      expect(formatCacheBytes(1536), '1.5 KB');
    });

    test('设备实测字节数（28,554,122 = 2.2MB + 26MB）→ 27.2 MB', () {
      // 是 1024 进制：28554122 / 1024^2 = 27.23 → 27.2 MB
      expect(formatCacheBytes(28554122), '27.2 MB');
      expect(formatCacheBytes(29884416), '28.5 MB');
      expect(formatCacheBytes(1288490189), '1.2 GB');
    });
  });

  group('VideoCacheUsage.label', () {
    test('空 → 0 B（不显示「0 个文件」）', () {
      expect(const VideoCacheUsage(0, 0).label, '0 B');
      expect(const VideoCacheUsage(0, 0).isEmpty, isTrue);
    });

    test('有文件 → 「大小 · N 个文件」', () {
      expect(const VideoCacheUsage(29884416, 2).label, '28.5 MB · 2 个文件');
      expect(const VideoCacheUsage(29884416, 2).isEmpty, isFalse);
    });
  });
}
