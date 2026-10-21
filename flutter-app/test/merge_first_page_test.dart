import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/util/merge_first_page.dart';

/// 测试用条目：id 判重，note 表示「这条数据的内容」，用来验证是否被更新。
class _Item {
  const _Item(this.id, [this.note = '']);
  final String id;
  final String note;
}

List<String> _ids(List<_Item> l) => l.map((e) => e.id).toList();

void main() {
  test('新项按 fresh 顺序插到顶部', () {
    final existing = [_Item('a'), _Item('b')];
    final fresh = [_Item('n1'), _Item('a', 'A2'), _Item('n2')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['n1', 'n2', 'a', 'b']);
  });

  test('已存在项用新数据原地更新，不重复出现', () {
    final existing = [_Item('a', 'old-a'), _Item('b', 'old-b')];
    final fresh = [_Item('a', 'new-a'), _Item('b', 'new-b')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['a', 'b']);
    expect(r[0].note, 'new-a');
    expect(r[1].note, 'new-b');
  });

  test('已加载的后续页原样保留、顺序不变', () {
    // c / d 模拟已经翻到的第二页
    final existing = [_Item('a'), _Item('b'), _Item('c'), _Item('d')];
    final fresh = [_Item('a', 'A2'), _Item('b', 'B2')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['a', 'b', 'c', 'd']);
    expect(r[0].note, 'A2');
    expect(r[1].note, 'B2');
    expect(r[2].note, '');
    expect(r[3].note, '');
  });

  test('新项 + 旧项更新 + 后续页保留 混合', () {
    final existing = [_Item('a'), _Item('b'), _Item('c')];
    final fresh = [_Item('n'), _Item('a', 'A2')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['n', 'a', 'b', 'c']);
    expect(r[1].note, 'A2');
  });

  test('existing 为空 → 直接就是新页', () {
    final r = mergeFirstPage(
      existing: <_Item>[],
      fresh: [_Item('x'), _Item('y')],
      idOf: (e) => e.id,
    );
    expect(_ids(r), ['x', 'y']);
  });

  test('fresh 为空 → 原样保留（不清空列表）', () {
    final existing = [_Item('a'), _Item('b')];
    final r = mergeFirstPage(existing: existing, fresh: <_Item>[], idOf: (e) => e.id);
    expect(_ids(r), ['a', 'b']);
  });

  test('服务端减少（fresh 是子集）→ 不在 fresh 里的也保留', () {
    final existing = [_Item('a'), _Item('b'), _Item('c')];
    final fresh = [_Item('a', 'A2')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['a', 'b', 'c']);
    expect(r[0].note, 'A2');
  });

  test('fresh 内部重复只认第一条', () {
    final r = mergeFirstPage(
      existing: <_Item>[],
      fresh: [_Item('a', '1'), _Item('a', '2')],
      idOf: (e) => e.id,
    );
    expect(_ids(r), ['a']);
    expect(r[0].note, '1');
  });

  test('空 id 不参与去重、原样保留，不崩', () {
    final existing = [_Item('', 'e0')];
    final fresh = [_Item('', 'f0'), _Item('a')];

    final r = mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(r), ['', 'a', '']);
    expect(r[0].note, 'f0');
    expect(r[2].note, 'e0');
  });

  test('不修改入参', () {
    final existing = [_Item('a')];
    final fresh = [_Item('n')];

    mergeFirstPage(existing: existing, fresh: fresh, idOf: (e) => e.id);

    expect(_ids(existing), ['a']);
    expect(_ids(fresh), ['n']);
  });
}
