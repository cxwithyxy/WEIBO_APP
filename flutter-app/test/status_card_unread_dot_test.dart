import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/unread.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';
import 'package:weibo_flutter/widgets/status_card.dart';

/// 未读绿点必须**看得见、位置对、能消失** —— 这份测试就钉这三件事。
///
/// 为什么需要它：真机上 MuMu 对 App 所在那块屏的 `screencap` 恒返回
/// `Status: -2`（实测不可用），「绿点长什么样、在不在最右」没法靠截图验收。
/// 这里用 widget 测试把「存在 + 绿色 + 8×8 圆 + 贴右边缘 + 语义标签 = 未读」
/// 全部断言死；真机侧再用 `uiautomator dump` 找同一个语义标签。
///
/// 注意：`UnreadStore` 的落盘是**防抖 1s**。测试里改完要 `cancelPendingSave()`
/// 把计时器砍掉 —— 不能调 `flush()`，那会真的去写文件（`path_provider` 在测试
/// 环境没有插件实现，会挂住不返回），而留着未触发的 Timer 又会让测试失败。

StatusDto _status(String id) => StatusDto(
  id: id,
  time: '2026/10/23 12:00:00',
  text: '测试微博',
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

Widget _wrap(String id, {required bool unread, String? secondId}) => MaterialApp(
  home: Scaffold(
    body: secondId == null
        ? StatusCard(status: _status(id), unread: unread)
        : Column(
            children: [
              StatusCard(status: _status(id), unread: unread),
              StatusCard(status: _status(secondId), unread: unread),
            ],
          ),
  ),
);

/// 绿点 = 8×8、圆形、`Colors.green.shade600` 的 Container。
Finder _dotFinder() => find.byWidgetPredicate((w) {
  if (w is! Container) return false;
  final d = w.decoration;
  return d is BoxDecoration &&
      d.shape == BoxShape.circle &&
      d.color == Colors.green.shade600;
});

/// 改未读集并砍掉防抖 Timer（不写盘，见文件头说明）。
void _seed(List<String> ids) {
  UnreadStore.instance.addAll(ids);
  UnreadStore.instance.cancelPendingSave();
}

void _markRead(String id) {
  UnreadStore.instance.markRead(id);
  UnreadStore.instance.cancelPendingSave();
}

void main() {
  setUp(() {
    UnreadStore.instance.clearAll();
    UnreadStore.instance.cancelPendingSave();
  });

  tearDown(() {
    UnreadStore.instance.clearAll();
    UnreadStore.instance.cancelPendingSave();
  });

  testWidgets('unread=true 且该条在未读集里 → 头部出现绿点', (tester) async {
    _seed(['200']);
    await tester.pumpWidget(_wrap('200', unread: true));
    await tester.pump();

    expect(_dotFinder(), findsOneWidget);
  });

  testWidgets('绿点是 8×8 的圆，颜色为 green.shade600', (tester) async {
    _seed(['201']);
    await tester.pumpWidget(_wrap('201', unread: true));
    await tester.pump();

    final dot = _dotFinder();
    expect(dot, findsOneWidget);
    final box = tester.widget<Container>(dot);
    final deco = box.decoration! as BoxDecoration;
    expect(deco.shape, BoxShape.circle);
    expect(deco.color, Colors.green.shade600);
    expect(tester.getSize(dot), const Size(8, 8));
  });

  testWidgets('绿点贴卡片右边缘、且落在第一行（用户名那一行）', (tester) async {
    _seed(['202']);
    await tester.pumpWidget(_wrap('202', unread: true));
    await tester.pump();

    final dotRect = tester.getRect(_dotFinder());
    final cardRect = tester.getRect(find.byType(StatusCard));

    // 右侧：紧贴卡片右边缘（而不是飘在中间）
    expect(cardRect.right - dotRect.right, lessThan(40));
    expect(dotRect.center.dx, greaterThan(cardRect.left + cardRect.width * 0.8));
    // 上方：落在头部那一行
    expect(dotRect.center.dy, lessThan(cardRect.top + 80));
  });

  testWidgets('绿点带「未读」语义标签（真机 uiautomator 靠它断言）', (tester) async {
    _seed(['203']);
    await tester.pumpWidget(_wrap('203', unread: true));
    await tester.pump();

    expect(
      find.bySemanticsLabel('未读'),
      findsOneWidget,
      reason: '绿点纯绘制、没有文字，必须靠语义标签才能在辅助功能/真机检查里被发现',
    );
  });

  testWidgets('unread=false（详情/搜索/我的等页面）→ 就算在未读集里也不显示', (tester) async {
    _seed(['204']);
    await tester.pumpWidget(_wrap('204', unread: false));
    await tester.pump();

    expect(_dotFinder(), findsNothing);
    expect(find.bySemanticsLabel('未读'), findsNothing);
  });

  testWidgets('该条不在未读集里 → 不显示绿点', (tester) async {
    _seed(['205']);
    await tester.pumpWidget(_wrap('206', unread: true));
    await tester.pump();

    expect(_dotFinder(), findsNothing);
  });

  testWidgets('标为已读后绿点自行消失（卡片监听 store，无需重建整列表）', (tester) async {
    _seed(['207']);
    await tester.pumpWidget(_wrap('207', unread: true));
    await tester.pump();
    expect(_dotFinder(), findsOneWidget);

    _markRead('207');
    await tester.pump();

    expect(_dotFinder(), findsNothing);
    expect(find.bySemanticsLabel('未读'), findsNothing);
  });

  testWidgets('同一列表里只有未读的那条带点（按 id 判定，不是整列表都点）', (tester) async {
    _seed(['300']);
    await tester.pumpWidget(_wrap('300', unread: true, secondId: '301'));
    await tester.pump();

    expect(_dotFinder(), findsOneWidget);
  });
}
