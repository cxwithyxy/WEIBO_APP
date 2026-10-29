import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/pages/replies_page.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';
import 'package:weibo_flutter/pages/detail_page.dart';

/// 「回复我的评论」页的行为约束。
///
/// 重点钉两件事：
///  ① 这个端点**一页条数不固定**（实测 2/5/1 条），所以「还有下一页」必须只看
///     `nextCursor`，不能用「不满 20 条就到头」——否则会漏掉后面的回复。
///  ② 正文开头的「回复@我:」前缀要剥掉，但正文中间的「回复@」不能动。

StatusDto _root(String id, String text, String author) => StatusDto(
  id: id,
  time: '2026/10/14 11:50:02',
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

MyCommentDto _reply(
  String id,
  String text, {
  String mine = '我当年说的',
  String? rootText,
}) => MyCommentDto(
  comment: CommentDto(
    id: id,
    time: '2026/10/14 15:00:00',
    text: text,
    likes: 0,
    floor: 0,
    isAuthor: false,
    images: const [],
    replyTo: CommentDto(
      id: 'mine$id',
      time: '',
      text: mine,
      likes: 0,
      floor: 0,
      isAuthor: false,
      images: const [],
    ),
    user: const UserDto(
      id: '9',
      name: '路人甲',
      avatar: '',
      verified: false,
      description: '',
      followers: 0,
      friends: 0,
      statuses: 0,
    ),
  ),
  root: rootText == null ? null : _root('root$id', rootText, '空客'),
);

MyCommentsPageDto _page(List<MyCommentDto> items, {int? cursor, int total = 0}) =>
    MyCommentsPageDto(comments: items, nextCursor: cursor, total: total);

Future<void> _pump(WidgetTester tester, RepliesPage page) async {
  await tester.pumpWidget(MaterialApp(home: page));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('正文前缀剥离', () {
    test('去掉开头的「回复@某某:」', () {
      expect(stripReplyPrefix('回复@陈轩大魔王:你说得对'), '你说得对');
      expect(stripReplyPrefix('回复<a href=x>@某人</a>:嗯'), '回复<a href=x>@某人</a>:嗯');
      expect(stripReplyPrefix('回复 @某某 ：好'), '好');
    });

    test('正文中间的「回复@」不动', () {
      expect(stripReplyPrefix('他说回复@A:才行'), '他说回复@A:才行');
    });

    test('没有前缀原样返回', () {
      expect(stripReplyPrefix('就是见不到我的su7'), '就是见不到我的su7');
    });
  });

  testWidgets('显示回复者、回复内容、我的原评论、原微博', (tester) async {
    await _pump(
      tester,
      RepliesPage(
        loader: (c) async => _page([
          _reply('r1', '回复@我:你说得对', mine: '缩小屏幕，屏幕越大越晕', rootText: '空客 A350'),
        ], total: 1),
      ),
    );

    expect(find.text('路人甲'), findsOneWidget);
    expect(find.text('你说得对'), findsOneWidget); // 前缀已剥
    expect(find.text('缩小屏幕，屏幕越大越晕'), findsOneWidget);
    expect(find.textContaining('空客 A350'), findsOneWidget);
    expect(find.text('回复 TA'), findsOneWidget);
  });

  testWidgets('一页只有 1 条但游标还在时，继续拉下一页', (tester) async {
    final cursors = <int?>[];
    await _pump(
      tester,
      RepliesPage(
        loader: (c) async {
          cursors.add(c);
          if (c == null) return _page([_reply('r1', '第一条回复')], cursor: 111);
          return _page([_reply('r2', '第二条回复')]);
        },
      ),
    );

    // 关键：绝不因为「不满一页」就停
    expect(cursors, [null, 111]);
    expect(find.text('第一条回复'), findsOneWidget);
    expect(find.text('第二条回复'), findsOneWidget);
  });

  testWidgets('游标为 null 就停，不重复请求', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      RepliesPage(
        loader: (c) async {
          calls++;
          return _page([_reply('r1', '只有这一条')]);
        },
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(calls, 1);
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('翻页重叠要去重', (tester) async {
    await _pump(
      tester,
      RepliesPage(
        loader: (c) async {
          if (c == null) {
            return _page([_reply('r1', '第一条回复')], cursor: 111);
          }
          // 故意把 r1 再返回一次（服务端游标重叠的兜底）
          return _page([_reply('r1', '第一条回复'), _reply('r2', '第二条回复')]);
        },
      ),
    );
    expect(find.text('第一条回复'), findsOneWidget);
    expect(find.text('第二条回复'), findsOneWidget);
  });

  testWidgets('空态与错误态', (tester) async {
    await _pump(tester, RepliesPage(loader: (c) async => _page([])));
    expect(find.text('还没有人回复你的评论'), findsOneWidget);
  });

  testWidgets('请求失败可重试', (tester) async {
    var attempt = 0;
    await _pump(
      tester,
      RepliesPage(
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

  testWidgets('点原微博进详情页', (tester) async {
    await _pump(
      tester,
      RepliesPage(
        loader: (c) async => _page([
          _reply('r1', '回复@我:你说得对', rootText: '原微博正文'),
        ]),
      ),
    );
    await tester.tap(find.textContaining('原微博正文'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(DetailPage), findsOneWidget);
  });
}
