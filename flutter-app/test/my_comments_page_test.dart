import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/pages/my_comments_page.dart';
import 'package:weibo_flutter/pages/detail_page.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';

/// 「我的评论」页的列表行为：注入 `loader`，不碰网络与 Rust。
///
/// 钉住四件事：
///  ① 首屏渲染评论正文 + 原微博摘要；
///  ② `nextCursor` 为 null 时**不再**拉下一页（不会死循环）；
///  ③ 有游标时上拉/滚到底能追加下一页；
///  ④ 空列表给出「还没有发过评论」，请求失败给出错误 + 重试。

StatusDto _root(String id, String text, String author) => StatusDto(
  id: id,
  time: '2026/10/14 14:43:42',
  text: text,
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
  user: UserDto(
    id: '1',
    name: author,
    avatar: '',
    verified: false,
    description: '',
    followers: 0,
    friends: 0,
    statuses: 0,
  ),
);

MyCommentDto _item(String id, String text, {String? rootText}) => MyCommentDto(
  comment: CommentDto(
    id: id,
    time: '2026/10/14 14:43:42',
    text: text,
    likes: 0,
    floor: 1,
    isAuthor: false,
    images: const [],
  ),
  root: rootText == null
      ? null
      : _root('root$id', rootText, '财联社APP'),
);

MyCommentsPageDto _page(
  List<MyCommentDto> items, {
  int? cursor,
  int total = 0,
}) => MyCommentsPageDto(comments: items, nextCursor: cursor, total: total);

Future<void> _pump(WidgetTester tester, MyCommentsPage page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump(); // 让 initState 的 postFrameCallback 跑起来
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('首屏显示评论正文与原微博摘要', (tester) async {
    await _pump(
      tester,
      MyCommentsPage(
        loader: (c) async => _page([
          _item('c1', '已经一手一台手机', rootText: '红果短剧杀疯了'),
        ], total: 1),
      ),
    );

    expect(find.text('已经一手一台手机'), findsOneWidget);
    expect(find.text('红果短剧杀疯了'), findsOneWidget);
    expect(find.textContaining('原微博'), findsOneWidget);
    expect(find.textContaining('财联社APP'), findsOneWidget);
  });

  testWidgets('游标为 null 时不再请求下一页', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      MyCommentsPage(
        loader: (c) async {
          calls++;
          return _page([_item('c1', '只有一页')]);
        },
      ),
    );

    // 反复滚动到底：游标 null ⇒ hasMore=false ⇒ 不该再发请求
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(calls, 1);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('有游标时能追加下一页', (tester) async {
    final cursors = <int?>[];
    await _pump(
      tester,
      MyCommentsPage(
        loader: (c) async {
          cursors.add(c);
          if (c == null) {
            return _page([_item('c1', '第一页的评论')], cursor: 111);
          }
          return _page([_item('c2', '第二页的评论')]);
        },
      ),
    );

    expect(find.text('第一页的评论'), findsOneWidget);
    // 首屏只有一条、没铺满一屏 → 页面会主动补拉下一页（另有上拉触发路径）
    await tester.pump(const Duration(milliseconds: 50));

    expect(cursors, [null, 111]); // 第二页用的就是第一页那个游标
    expect(find.text('第二页的评论'), findsOneWidget);
  });

  testWidgets('空列表显示空态文案', (tester) async {
    await _pump(tester, MyCommentsPage(loader: (c) async => _page([])));
    expect(find.text('还没有发过评论'), findsOneWidget);
  });

  testWidgets('请求失败显示错误与重试', (tester) async {
    var attempt = 0;
    await _pump(
      tester,
      MyCommentsPage(
        loader: (c) async {
          attempt++;
          throw Exception('网络炸了');
        },
      ),
    );

    expect(find.textContaining('重试'), findsOneWidget);
    expect(attempt, 1);

    await tester.tap(find.textContaining('重试'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(attempt, 2);
  });

  testWidgets('原微博可点进详情页', (tester) async {
    await _pump(
      tester,
      MyCommentsPage(
        loader: (c) async => _page([
          _item('c1', '我的评论', rootText: '原微博正文'),
        ]),
      ),
    );

    await tester.tap(find.text('原微博正文'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 详情页会去拉真实接口（测试里没有 Rust 侧实现），所以只断言「确实跳到了详情页」
    expect(find.byType(DetailPage), findsOneWidget);
  });
}
