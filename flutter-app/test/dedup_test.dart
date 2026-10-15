import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/dedup.dart';

void main() {
  group('dedupById —— 信息流防重复的核心', () {
    test('批内去重，保留首次出现的顺序（不排序）', () {
      final out = dedupById<int>([3, 1, 3, 2, 1], (e) => e.toString());
      expect(out, [3, 1, 2]);
    });

    test('seen 跨批累积 —— 这正是翻页不重复的关键', () {
      final seen = <String>{};
      final p1 = dedupById(['a', 'b'], (e) => e, seen: seen);
      final p2 = dedupById(['b', 'c'], (e) => e, seen: seen);
      final p3 = dedupById(['c', 'd', 'a'], (e) => e, seen: seen);

      expect(p1, ['a', 'b']);
      expect(p2, ['c'], reason: 'b 第一批已出现 → 必须丢');
      expect(p3, ['d'], reason: 'c、a 都已出现过 → 必须丢');
      expect(seen, {'a', 'b', 'c', 'd'});
    });

    test('整页都是重复时返回空 —— 调用方据此判断「这一页没新东西」', () {
      final seen = <String>{'x', 'y'};
      expect(dedupById(['x', 'y'], (e) => e, seen: seen), isEmpty);
    });

    test('不传 seen 时只做批内去重，不影响外部', () {
      final a = dedupById(['x'], (e) => e);
      final b = dedupById(['x'], (e) => e);
      expect(a, ['x']);
      expect(b, ['x'], reason: '两次调用互相独立 —— 不传 seen 就不该有共享状态');
    });

    test('没有 id 的条目原样保留（不替服务端决定丢弃内容）', () {
      expect(dedupById(['', 'a', ''], (e) => e), ['', 'a', '']);
    });

    test('空输入返回空', () {
      expect(dedupById<String>([], (e) => e), isEmpty);
    });
  });
}
