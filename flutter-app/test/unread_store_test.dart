import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/unread.dart';

/// `UnreadStore` 的集合语义与落盘。用 `forTest` 注入内存读写，
/// 绕开 path_provider（真机上才是 `unread/<feed>.json`）。
void main() {
  late Map<String, Set<String>> disk;
  late UnreadStore store;

  setUp(() {
    disk = <String, Set<String>>{};
    store = UnreadStore.forTest(
      reader: (feed) async => Set<String>.of(disk[feed] ?? <String>{}),
      writer: (feed, ids) async => disk[feed] = Set<String>.of(ids),
      saveDelay: const Duration(milliseconds: 5),
    );
  });

  test('load 读回磁盘上的未读集', () async {
    disk['following'] = {'a', 'b'};
    await store.load('following');
    expect(store.contains('a'), isTrue);
    expect(store.count, 2);
  });

  test('addAll 去重、忽略空 id', () async {
    await store.load('following');
    store.addAll(['a', 'b', 'a', '']);
    expect(store.count, 2);
    expect(store.contains('b'), isTrue);
  });

  test('markRead / markReadAll 从集合移除', () async {
    await store.load('following');
    store.addAll(['a', 'b', 'c']);
    store.markRead('a');
    store.markReadAll(['b', 'x']);
    expect(store.count, 1);
    expect(store.contains('c'), isTrue);
  });

  test('clearAll 返回清掉的条数并清空', () async {
    await store.load('following');
    store.addAll(['a', 'b', 'c']);
    expect(store.clearAll(), 3);
    expect(store.count, 0);
    expect(store.clearAll(), 0);
  });

  test('clearAll 之后新 addAll 仍能进（回归）', () async {
    await store.load('following');
    store.addAll(['a']);
    store.clearAll();
    store.addAll(['b']);
    expect(store.contains('b'), isTrue);
    expect(store.contains('a'), isFalse);
  });

  test('retain 剪掉不在列表里的 id', () async {
    await store.load('following');
    store.addAll(['a', 'b', 'c']);
    store.retain(['a', 'c']);
    expect(store.count, 2);
    expect(store.contains('b'), isFalse);
  });

  test('flush 把当前 feed 的未读集写盘', () async {
    await store.load('following');
    store.addAll(['a', 'b']);
    await store.flush();
    expect(disk['following'], {'a', 'b'});
  });

  test('按 feed 隔离：切换后各自独立', () async {
    disk['home'] = {'h1'};
    disk['following'] = {'f1'};
    await store.load('home');
    expect(store.contains('h1'), isTrue);
    expect(store.contains('f1'), isFalse);
    await store.load('following');
    expect(store.contains('f1'), isTrue);
    expect(store.contains('h1'), isFalse);
  });

  test('contains("") 恒为 false', () async {
    await store.load('following');
    store.addAll(['a']);
    expect(store.contains(''), isFalse);
  });

  test('落盘失败不抛，内存仍生效', () async {
    final s = UnreadStore.forTest(
      reader: (feed) async => <String>{},
      writer: (feed, ids) async => throw Exception('disk full'),
      saveDelay: const Duration(milliseconds: 5),
    );
    await s.load('following');
    s.addAll(['a']);
    await s.flush(); // 不应抛出
    expect(s.contains('a'), isTrue);
  });
}
