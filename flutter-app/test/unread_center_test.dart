import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/unread_center.dart';

/// 未读「穿越判定」纯逻辑 + 未读集纯操作。
///
/// 规则要点（cx 2026-10-23 修订）：标题必须**从中线以下被推到中线以上**那一下
/// 才算读；首次观测就在中线以上的不算（下拉刷新插顶部的新微博保持未读）；
/// 兜底：被推出屏幕顶部（底边 < 0）也算。
void main() {
  group('crossedToRead —— 穿越判定', () {
    test('从下往上穿过中线（prev>0 → now<0）→ 已读', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 40},
          nowTitleY: {'a': -10},
        ),
        {'a'},
      );
    });

    test('首次出现就在中线以上（prev 缺失）→ 不算读【关键回归】', () {
      // 下拉刷新后新微博插在顶部：一进来就在中线以上，没被推过。
      expect(
        crossedToRead(
          prevTitleY: <String, double>{},
          nowTitleY: {'new1': -120, 'new2': -30},
        ),
        isEmpty,
      );
    });

    test('从上往下（prev<0 → now>0）→ 不算读', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': -50},
          nowTitleY: {'a': 80},
        ),
        isEmpty,
      );
    });

    test('一直在线以下（prev>0 → now>0）→ 不算读', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 200},
          nowTitleY: {'a': 10},
        ),
        isEmpty,
      );
    });

    test('一直在线以上（prev<0 → now<0）→ 不算读', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': -80},
          nowTitleY: {'a': -5},
        ),
        isEmpty,
      );
    });

    test('边界：prev == 0 → now < 0 算读（prev>=0）', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 0},
          nowTitleY: {'a': -0.1},
        ),
        {'a'},
      );
    });

    test('边界：now == 0 不算读（要 now<0 才算过线）', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 50},
          nowTitleY: {'a': 0},
        ),
        isEmpty,
      );
    });

    test('滚出屏幕顶部（底边 < 0）→ 算读，哪怕标题仍在中线以下', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 300},
          nowTitleY: {'a': 100},
          itemBottomY: {'a': -1},
        ),
        {'a'},
      );
    });

    test('底边 == 0 不算（严格 < 0）', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 300},
          nowTitleY: {'a': 100},
          itemBottomY: {'a': 0},
        ),
        isEmpty,
      );
    });

    test('滚出顶部的兜底对「首次出现就在线以上」也生效', () {
      // prev 缺失（首次观测），但底边已 < 0：用户确实把它推走了 → 算读。
      expect(
        crossedToRead(
          prevTitleY: <String, double>{},
          nowTitleY: {'a': -200},
          itemBottomY: {'a': -30},
        ),
        {'a'},
      );
    });

    test('同一次滚动多条穿越 → 全部返回', () {
      expect(
        crossedToRead(
          prevTitleY: {'a': 10, 'b': 30, 'c': -5},
          nowTitleY: {'a': -1, 'b': -20, 'c': -9},
        ),
        {'a', 'b'},
        reason: 'c 本来就在线以上，不是穿越',
      );
    });

    test('空 map → 空，不崩', () {
      expect(
        crossedToRead(prevTitleY: const {}, nowTitleY: const {}),
        isEmpty,
      );
    });

    test('id 只在 prev（已消失）→ 不误判、不崩', () {
      expect(
        crossedToRead(
          prevTitleY: {'gone': 50},
          nowTitleY: {'now': -10},
        ),
        isEmpty,
      );
    });

    test('id 只在 now（新增）→ 不算读', () {
      expect(
        crossedToRead(
          prevTitleY: {'old': 50},
          nowTitleY: {'old': 50, 'added': -10},
        ),
        isEmpty,
      );
    });

    test('空 id 被忽略', () {
      expect(
        crossedToRead(
          prevTitleY: {'': 40},
          nowTitleY: {'': -10},
        ),
        isEmpty,
      );
    });
  });

  group('未读集纯操作', () {
    test('addAll 去重 + 忽略空 id', () {
      final r = unreadAddAll({'a'}, ['a', 'b', '', 'b', 'c']);
      expect(r, {'a', 'b', 'c'});
    });

    test('markRead 幂等：不在集合里原样返回', () {
      final src = {'a', 'b'};
      expect(unreadMarkRead(src, 'a'), {'b'});
      expect(identical(unreadMarkRead(src, 'x'), src), isTrue);
      expect(unreadMarkRead(src, ''), same(src));
    });

    test('markReadAll 批量移除', () {
      expect(unreadMarkReadAll({'a', 'b', 'c'}, ['a', 'c', 'x']), {'b'});
      expect(unreadMarkReadAll(const {}, ['a']), isEmpty);
    });

    test('retain 只保留仍在列表里的 id', () {
      expect(unreadRetain({'a', 'b', 'c'}, {'a', 'c', 'z'}), {'a', 'c'});
    });

    test('retain 无变化时返回同一实例（省一次 notify/落盘）', () {
      final src = {'a', 'b'};
      expect(identical(unreadRetain(src, {'a', 'b', 'c'}), src), isTrue);
    });

    test('retain 空集返回原实例', () {
      final src = <String>{};
      expect(identical(unreadRetain(src, {'a'}), src), isTrue);
    });

    test('retain present 为空 / 全空 id → 原样保留（防误清空）', () {
      final src = {'a', 'b'};
      expect(identical(unreadRetain(src, <String>{}), src), isTrue);
      expect(identical(unreadRetain(src, {''}), src), isTrue);
    });
  });
}
