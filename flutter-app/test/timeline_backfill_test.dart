import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';
import 'package:weibo_flutter/util/timeline_backfill.dart';

/// 造一条微博。`time` 是 core 已格式化的 `YYYY/MM/DD HH:mm:SS`，
/// 定长 → 字典序就是时间序（shouldContinueBackfill 直接按字典序比）。
StatusDto _s(String id, String time) => StatusDto(
  id: id,
  time: time,
  text: 't',
  source: '微博网页版',
  reposts: 0,
  comments: 0,
  likes: 0,
  liked: false,
  images: const [],
  isAd: false,
  isLongText: false,
  isVideo: false,
  videoFromRetweeted: false,
);

/// mergeBackfillPages 的测试条目（泛型，不必是 StatusDto）
class _Item {
  const _Item(this.id);
  final String id;
}

List<String> _ids(List<_Item> l) => l.map((e) => e.id).toList();

void main() {
  // ------------------------------------------------------------------
  // shouldContinueBackfill —— 「该不该继续补」
  // ------------------------------------------------------------------
  group('shouldContinueBackfill —— 停止条件', () {
    const known = '2026/10/21 08:00:00';

    test('id 命中即停（即使本页还很新）', () {
      // 本页时间是 12:00，远晚于旧内容的 08:00，但出现了旧 id → 已接上，停。
      final page = [_s('old-1', '2026/10/21 12:00:00')];
      expect(
        shouldContinueBackfill(
          knownIds: {'old-1'},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
        ),
        isFalse,
      );
    });

    test('id 命中优先于时间覆盖：页里既有旧 id 也有很新的条目 → 停', () {
      // 12:00 的新条目本会让人以为还要继续，但同一页已接上 old-1。
      final page = [
        _s('new-1', '2026/10/21 15:00:00'),
        _s('old-1', '2026/10/21 07:00:00'),
        _s('new-2', '2026/10/21 13:00:00'),
      ];
      expect(
        shouldContinueBackfill(
          knownIds: {'old-1'},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
        ),
        isFalse,
      );
    });

    test('首屏跳过 id 命中：置顶微博 id 在 knownIds 里也不能一进来就停', () {
      // 第一页：置顶（时间很旧、id 几天不变）+ 一批很新的条目。
      final page = [
        _s('pinned', '2026/10/15 09:00:00'),
        _s('n1', '2026/10/21 15:00:00'),
        _s('n2', '2026/10/21 12:00:00'),
      ];
      // 按 id 会命中 pinned；按全页 min 会命中置顶的 10-15。首屏两者都必须忽略。
      expect(
        shouldContinueBackfill(
          knownIds: {'pinned'},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
          isFirstPage: true,
        ),
        isTrue,
        reason: '置顶不能让刷新一页都不补',
      );
    });

    test('同样的置顶页放到非首屏（补拉页）→ id 命中即停', () {
      final page = [
        _s('pinned', '2026/10/15 09:00:00'),
        _s('n1', '2026/10/21 15:00:00'),
        _s('n2', '2026/10/21 12:00:00'),
      ];
      expect(
        shouldContinueBackfill(
          knownIds: {'pinned'},
          newestKnownTime: known,
          page: page,
          pagesFetched: 1,
        ),
        isFalse,
      );
    });

    test('时间兜底取最后一条，不被前置置顶的旧时间骗到', () {
      // knownIds 为空（置顶不在旧缓存里），只看时间：
      // 最后一条 12:00 > 08:00 → 继续；若误用 min（置顶 10-15）就会错误停下。
      final page = [
        _s('pinned', '2026/10/15 09:00:00'),
        _s('n1', '2026/10/21 15:00:00'),
        _s('n2', '2026/10/21 12:00:00'),
      ];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
          isFirstPage: true,
        ),
        isTrue,
      );
    });

    test('时间覆盖即停（id 永远等不到时的兜底）', () {
      // 旧内容最新 08:00；本页最旧 07:00 <= 08:00 → 时间区间已覆盖。
      final page = [
        _s('n1', '2026/10/21 10:00:00'),
        _s('n2', '2026/10/21 07:00:00'),
      ];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
        ),
        isFalse,
      );
    });

    test('时间正好等于边界也算覆盖（<= 而不是 <）', () {
      final page = [_s('n1', '2026/10/21 08:00:00')];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
        ),
        isFalse,
      );
    });

    test('空页即停（服务端没内容了）', () {
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: const <StatusDto>[],
          pagesFetched: 0,
        ),
        isFalse,
      );
    });

    test('还没接上、也没到上限 → 继续', () {
      final page = [
        _s('n1', '2026/10/21 12:00:00'),
        _s('n2', '2026/10/21 10:00:00'),
      ];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 0,
        ),
        isTrue,
      );
    });

    test('安全上限截断：pagesFetched >= maxPages → 停', () {
      final page = [_s('n1', '2026/10/21 12:00:00')];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: kMaxBackfillPages,
        ),
        isFalse,
      );
      // 差一页时仍继续
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: kMaxBackfillPages - 1,
        ),
        isTrue,
      );
    });

    test('自定义 maxPages 生效', () {
      final page = [_s('n1', '2026/10/21 12:00:00')];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 2,
          maxPages: 3,
        ),
        isTrue,
      );
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 3,
          maxPages: 3,
        ),
        isFalse,
      );
    });

    test('knownIds 为空且页内任意时间都更晚 → 一直继续', () {
      final page = [_s('n1', '2026/10/21 23:59:59')];
      expect(
        shouldContinueBackfill(
          knownIds: const {},
          newestKnownTime: known,
          page: page,
          pagesFetched: 1,
        ),
        isTrue,
      );
    });
  });

  // ------------------------------------------------------------------
  // mergeBackfillPages —— 「怎么合并页」
  // ------------------------------------------------------------------
  group('mergeBackfillPages —— 顺序与去重', () {
    test('多页顺序正确：p1 + p2 + p3 + existing', () {
      final p1 = [_Item('a'), _Item('b')];
      final p2 = [_Item('c'), _Item('d')];
      final p3 = [_Item('e')];
      final existing = [_Item('f'), _Item('g')];

      final r = mergeBackfillPages<_Item>(
        existing: existing,
        fetchedNewestFirst: [p1, p2, p3],
        idOf: (e) => e.id,
      );

      expect(_ids(r), ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
    });

    test('跨页去重：后面的页重复前面的页 → 只留首次', () {
      final r = mergeBackfillPages<_Item>(
        existing: [_Item('f')],
        fetchedNewestFirst: [
          [_Item('a'), _Item('b')],
          [_Item('b'), _Item('c')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b', 'c', 'f']);
    });

    test('页内有重复 → 批内去重', () {
      final r = mergeBackfillPages<_Item>(
        existing: const <_Item>[],
        fetchedNewestFirst: [
          [_Item('a'), _Item('a'), _Item('b')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b']);
    });

    test('全重复页：每页都与已有内容重复 → 不重复出现', () {
      final existing = [_Item('a'), _Item('b')];
      final r = mergeBackfillPages<_Item>(
        existing: existing,
        fetchedNewestFirst: [
          [_Item('a'), _Item('b')],
          [_Item('a'), _Item('b')],
          [_Item('a'), _Item('b')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b']);
    });

    test('新页与 existing 重叠 → 新页优先保留，existing 重复项丢掉', () {
      final r = mergeBackfillPages<_Item>(
        existing: [_Item('b'), _Item('c')],
        fetchedNewestFirst: [
          [_Item('a'), _Item('b')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b', 'c']);
    });

    test('existing 为空的边界 → 就是新页顺序', () {
      final r = mergeBackfillPages<_Item>(
        existing: const <_Item>[],
        fetchedNewestFirst: [
          [_Item('a'), _Item('b')],
          [_Item('c')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b', 'c']);
    });

    test('没抓到任何页 → 原样保留 existing，不清空', () {
      final existing = [_Item('a'), _Item('b')];
      final r = mergeBackfillPages<_Item>(
        existing: existing,
        fetchedNewestFirst: const [],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['a', 'b']);
    });

    test('空 id 不参与去重、原样保留', () {
      final r = mergeBackfillPages<_Item>(
        existing: [_Item(''), _Item('b')],
        fetchedNewestFirst: [
          [_Item(''), _Item('a')],
        ],
        idOf: (e) => e.id,
      );
      expect(_ids(r), ['', 'a', '', 'b']);
    });

    test('不修改入参', () {
      final existing = [_Item('a')];
      final p1 = [_Item('n1')];
      final p2 = [_Item('n2')];
      final fetched = [p1, p2];

      mergeBackfillPages<_Item>(
        existing: existing,
        fetchedNewestFirst: fetched,
        idOf: (e) => e.id,
      );

      expect(_ids(existing), ['a']);
      expect(_ids(p1), ['n1']);
      expect(_ids(p2), ['n2']);
      expect(fetched.length, 2);
    });
  });

  // ------------------------------------------------------------------
  // 上限与停止原因 —— 「被截断」必须能和「真接上」区分开
  // ------------------------------------------------------------------
  group('backfillStopReason / 上限', () {
    const known = '2026/10/21 08:00:00';
    final newer = [_s('n1', '2026/10/21 12:00:00')];

    test('还没接上 → null（继续补）', () {
      expect(
        backfillStopReason(
          knownIds: const {},
          newestKnownTime: known,
          page: newer,
          pagesFetched: 0,
        ),
        isNull,
      );
    });

    test('id 命中 → connected', () {
      expect(
        backfillStopReason(
          knownIds: {'x'},
          newestKnownTime: known,
          page: [_s('x', '2026/10/21 12:00:00')],
          pagesFetched: 1,
        ),
        BackfillStop.connected,
      );
    });

    test('时间覆盖 → connected', () {
      expect(
        backfillStopReason(
          knownIds: const {},
          newestKnownTime: known,
          page: [_s('n1', '2026/10/21 07:00:00')],
          pagesFetched: 1,
        ),
        BackfillStop.connected,
      );
    });

    test('空页 → emptyPage', () {
      expect(
        backfillStopReason(
          knownIds: const {},
          newestKnownTime: known,
          page: const <StatusDto>[],
          pagesFetched: 1,
        ),
        BackfillStop.emptyPage,
      );
    });

    test('到上限且未接上 → capReached（要留警告信号）', () {
      expect(
        backfillStopReason(
          knownIds: const {},
          newestKnownTime: known,
          page: newer,
          pagesFetched: kMaxBackfillPages,
        ),
        BackfillStop.capReached,
      );
    });

    test('恰好在上限这一页接上 → connected，不误报 capReached', () {
      expect(
        backfillStopReason(
          knownIds: const {},
          newestKnownTime: known,
          page: [_s('n1', '2026/10/21 07:00:00')],
          pagesFetched: kMaxBackfillPages,
        ),
        BackfillStop.connected,
      );
      expect(
        backfillStopReason(
          knownIds: {'x'},
          newestKnownTime: known,
          page: [_s('x', '2026/10/21 12:00:00')],
          pagesFetched: kMaxBackfillPages,
        ),
        BackfillStop.connected,
      );
    });

    test('上限按实测密度提到 60 页，限速 120ms', () {
      expect(kMaxBackfillPages, 60, reason: '15 页只够 6.5h，60 页 ≈ 24h');
      expect(kBackfillPageDelay, const Duration(milliseconds: 120));
    });
  });
}
