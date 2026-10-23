import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/cache.dart';

/// FeedSnapshot 新增的可选 `page` 字段：
///  - 新快照要能往返；
///  - 老快照（没有 `page`）读出来必须是 null —— 调用方据此回退旧算法。
void main() {
  group('FeedSnapshot JSON —— page 往返 / 老快照兼容', () {
    test('带 page：toJson → jsonEncode → jsonDecode → fromJson 全一致', () {
      final s = FeedSnapshot(pages: ['p1', 'p2'], cursor: '7', page: 8);

      final back = FeedSnapshot.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>,
      );

      expect(back.pages, ['p1', 'p2']);
      expect(back.cursor, '7');
      expect(back.page, 8);
    });

    test('page / cursor 为 null：往返仍是 null', () {
      final s = FeedSnapshot(pages: ['x'], cursor: null, page: null);

      final back = FeedSnapshot.fromJson(s.toJson());

      expect(back.pages, ['x']);
      expect(back.cursor, isNull);
      expect(back.page, isNull);
    });

    test('老快照没有 page 字段 → null（向后兼容，调用方回退按页数推）', () {
      final back = FeedSnapshot.fromJson(
        jsonDecode('{"pages":["p1","p2"],"cursor":"3"}')
            as Map<String, Object?>,
      );

      expect(back.pages, ['p1', 'p2']);
      expect(back.cursor, '3');
      expect(
        back.page,
        isNull,
        reason: '没有 page 必须回退旧算法，不能瞎猜一个页码',
      );
    });

    test('page 是 JSON 数字（可能被解码成 double）也能读出 int', () {
      final back = FeedSnapshot.fromJson({
        'pages': <Object?>[],
        'cursor': '1',
        'page': 5.0,
      });

      expect(back.page, 5);
    });

    test('toJson 一定带上 page 键（哪怕是 null），供落盘', () {
      final m = FeedSnapshot(pages: ['a'], cursor: '2', page: 3).toJson();
      expect(m.containsKey('page'), isTrue);
      expect(m['page'], 3);
    });
  });
}
