import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/video_url.dart';

void main() {
  final now = DateTime.utc(2026, 10, 22, 0, 0, 0);
  final epoch = now.millisecondsSinceEpoch ~/ 1000;

  String urlWithExpiry(int expires) =>
      'http://f.video.weibocdn.com/o0/abc.mp4?label=mp4_720p&template=x'
      '&Expires=$expires&ssig=abc';

  group('videoUrlExpiry', () {
    test('解析 query 里的 Expires（epoch 秒）', () {
      final e = videoUrlExpiry(urlWithExpiry(epoch + 3600));
      expect(e, isNotNull);
      expect(e!.millisecondsSinceEpoch, (epoch + 3600) * 1000);
    });

    test('没有 Expires → null', () {
      expect(
        videoUrlExpiry('http://f.video.weibocdn.com/a.mp4?label=x'),
        isNull,
      );
    });

    test('空串 / 坏 URL → null', () {
      expect(videoUrlExpiry(''), isNull);
      expect(videoUrlExpiry('not a url'), isNull);
    });
  });

  group('isVideoUrlFresh', () {
    test('剩余 > 60s 才新鲜（60s 安全余量）', () {
      expect(isVideoUrlFresh(urlWithExpiry(epoch + 61), now: now), isTrue);
      expect(isVideoUrlFresh(urlWithExpiry(epoch + 60), now: now), isFalse);
      expect(isVideoUrlFresh(urlWithExpiry(epoch + 59), now: now), isFalse);
    });

    test('已过期 → 不新鲜', () {
      expect(isVideoUrlFresh(urlWithExpiry(epoch - 1), now: now), isFalse);
      // 正是 cx 现场那种「过期 7343 分钟」的样本
      expect(
        isVideoUrlFresh(urlWithExpiry(epoch - 7343 * 60), now: now),
        isFalse,
      );
    });

    test('没有 Expires 的链接按可用处理，空串不可用', () {
      expect(
        isVideoUrlFresh('http://f.video.weibocdn.com/a.mp4', now: now),
        isTrue,
      );
      expect(isVideoUrlFresh('', now: now), isFalse);
    });
  });

  group('formatBytes', () {
    test('B / KB / MB', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(12 * 1024 * 1024), '12.0 MB');
    });
  });
}
