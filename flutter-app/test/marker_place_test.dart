import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/marker_place.dart';

void main() {
  group('markerInsertIndex —— 「上次刷到这里」该插在哪', () {
    // 列表顺序永远是「新 → 旧」（id 递减）
    final normal = ['900', '800', '700', '600'];

    test('锚点正常在列表中：落在它后面那条之前', () {
      // 锚点 800（第 2 条）→ 插在 700 之前 = 下标 2
      expect(markerInsertIndex(normal, '800'), 2);
    });

    test('锚点不在列表但夹在中间 → 找到它"本该在"的位置', () {
      // 750 夹在 800 和 700 之间 → 插在 700 之前 = 下标 2
      expect(markerInsertIndex(normal, '750'), 2);
    });

    test('锚点比整页都旧 → 落到末尾（整页都比它新 = 都还没读）', () {
      expect(markerInsertIndex(normal, '100'), normal.length);
    });

    test('锚点比整页都新 → 落到最前（整页都比它旧 = 都读过了）', () {
      expect(markerInsertIndex(normal, '990'), 0);
    });

    test('空列表 → 0，不崩', () {
      expect(markerInsertIndex(const [], '123'), 0);
    });

    test('畸形 id 不猜、不崩：一律当"不比它更旧"', () {
      expect(markerInsertIndex(const ['abc', ''], '123'), 2);
    });
  });

  // 🔴 回归：真机上「标记一直挂在顶部」就是这一族例子翻车
  //
  // 关注流第一页页首会插一条**置顶微博**：id 极小、却排在最前面。
  // 只看 id 绝对大小会得出「整页都比锚点新」→ 把标记插到列表顶部。
  // 位置计算必须先跳过开头的逆序段，再按相对顺序定位。
  group('markerInsertIndex —— 含置顶微博（开场逆序）', () {
    const pin = '5354396839314930'; // 置顶：id 最小，却排第一
    final ids = [pin, '5354678630224451', '5354414459848167'];

    test('跳过置顶后按相对顺序定位', () {
      // 锚点比第 2 条旧、比第 3 条新 → 插在第 3 条之前 = 下标 2
      expect(markerInsertIndex(ids, '5354414530363583'), 2);
    });

    test('锚点比所有非置顶条目都旧 → 落到末尾（不是顶部！）', () {
      expect(markerInsertIndex(ids, '5354414459848160'), ids.length);
    });

    test('跳过置顶后锚点比其余都新 → 紧接着置顶之后（下标 1）', () {
      expect(markerInsertIndex(ids, '5354699999999999'), 1);
    });

    test('连续多条置顶（多段逆序）也能跳过', () {
      final multi = [pin, '5354396839314931', '5354678630224451'];
      // 前两条都算逆序段（id 递增）→ 从第 3 条开始比
      expect(markerInsertIndex(multi, '5354699999999999'), 2);
    });
  });

  group('isOlderId', () {
    test('超 int64 的 16 位数字也不会溢出', () {
      expect(isOlderId('5354414459848167', '5354678630224451'), true);
      expect(isOlderId('5354678630224451', '5354414459848167'), false);
    });

    test('相等 → false（不是"更旧"）', () {
      expect(isOlderId('123', '123'), false);
    });

    test('非法输入 → false（不猜）', () {
      expect(isOlderId('abc', '123'), false);
      expect(isOlderId('', '123'), false);
    });
  });
}
