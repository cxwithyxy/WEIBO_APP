import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/status_write.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';

StatusDto _status({bool liked = false, int likes = 0}) => StatusDto(
  id: '1',
  time: '2026/10/21 12:00:00',
  text: '测试微博',
  source: '微博网页版',
  reposts: 0,
  comments: 0,
  likes: likes,
  liked: liked,
  images: const [],
  isAd: false,
  isLongText: false,
  isVideo: false,
  videoFromRetweeted: false,
);

void main() {
  group('syncStatusCache —— 刷成功/刷失败两条分支', () {
    test('取到新原文：写缓存 + 同步服务端 liked/likes，不删缓存', () async {
      String? saved;
      var removed = false;
      StatusDto? applied;

      await syncStatusCache(
        fetch: () async =>
            StatusRawDto(raw: '{"attitudes_status":1}', status: _status(liked: true, likes: 3)),
        save: (raw) async {
          saved = raw;
          return true;
        },
        remove: () async => removed = true,
        applyServerState: (s) => applied = s,
      );

      expect(saved, '{"attitudes_status":1}', reason: '应把服务端新原文写回缓存');
      expect(removed, isFalse, reason: '成功路径不能删缓存');
      expect(applied?.liked, isTrue);
      expect(applied?.likes, 3);
    });

    test('重拉失败：删掉旧缓存（绝不留旧值）', () async {
      var removed = false;
      var saved = false;

      await syncStatusCache(
        fetch: () async => throw Exception('network down'),
        save: (_) async {
          saved = true;
          return true;
        },
        remove: () async => removed = true,
      );

      expect(removed, isTrue, reason: '重拉失败必须把旧缓存删掉');
      expect(saved, isFalse);
    });

    test('原文为空：按失败处理，删掉旧缓存', () async {
      var removed = false;
      await syncStatusCache(
        fetch: () async => StatusRawDto(raw: '   ', status: _status()),
        save: (_) async => true,
        remove: () async => removed = true,
        attempts: 1,
      );
      expect(removed, isTrue);
    });

    test('落盘失败：也删掉旧缓存', () async {
      var removed = false;
      await syncStatusCache(
        fetch: () async => StatusRawDto(raw: '{"ok":1}', status: _status()),
        save: (_) async => false,
        remove: () async => removed = true,
      );
      expect(removed, isTrue);
    });

    test('读后写延迟：第一次重拉是旧值时重试，拿到新值再写盘', () async {
      var calls = 0;
      String? saved;
      var removed = false;

      await syncStatusCache(
        // 第一次返回点赞前的旧值，第二次才反映已点赞
        fetch: () async {
          calls++;
          return StatusRawDto(
            raw: calls == 1 ? '{"attitudes_status":0}' : '{"attitudes_status":1}',
            status: _status(liked: calls != 1, likes: calls == 1 ? 0 : 1),
          );
        },
        save: (raw) async {
          saved = raw;
          return true;
        },
        remove: () async => removed = true,
        expect: (s) => s.liked,
        retryDelay: Duration.zero,
      );

      expect(calls, 2, reason: '旧值要重拉');
      expect(saved, '{"attitudes_status":1}', reason: '写盘的是重拉后的新值');
      expect(removed, isFalse);
    });

    test('重拉始终是旧值：删掉缓存而不是写旧值', () async {
      var calls = 0;
      var saved = false;
      var removed = false;

      await syncStatusCache(
        fetch: () async {
          calls++;
          return StatusRawDto(raw: '{"attitudes_status":0}', status: _status(liked: false));
        },
        save: (_) async {
          saved = true;
          return true;
        },
        remove: () async => removed = true,
        expect: (s) => s.liked,
        attempts: 3,
        retryDelay: Duration.zero,
      );

      expect(calls, 3);
      expect(saved, isFalse, reason: '不能把确认不了的旧值写进缓存');
      expect(removed, isTrue);
    });
  });

  group('mutateStatus —— 写操作统一入口', () {
    test('写成功后触发刷新', () async {
      final refreshed = <String>[];
      await mutateStatus('42', () async {}, refresh: (mid) async => refreshed.add(mid));
      await Future<void>.delayed(Duration.zero);
      expect(refreshed, ['42']);
    });

    test('写失败：异常照抛，且不刷缓存', () async {
      var refreshed = false;
      await expectLater(
        mutateStatus(
          '42',
          () async => throw Exception('ok=0 invalid'),
          refresh: (mid) async => refreshed = true,
        ),
        throwsException,
      );
      await Future<void>.delayed(Duration.zero);
      expect(refreshed, isFalse, reason: '写入没成功就不该刷缓存');
    });
  });
}
