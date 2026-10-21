import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weibo_flutter/data/attitude.dart';
import 'package:weibo_flutter/src/rust/api/dto.dart';
import 'package:weibo_flutter/widgets/status_card.dart';

StatusDto _status({required bool liked, required int likes}) => StatusDto(
  id: '100',
  time: '2026/10/21 12:00:00',
  text: '测试微博',
  source: '微博网页版',
  reposts: 0,
  comments: 0,
  likes: likes,
  liked: liked,
  images: const [],
  isAd: false,
  isLongText: false,
  isVideo: false,
  videoFromRetweeted: false,
);

Widget _wrap(StatusDto s) =>
    MaterialApp(home: Scaffold(body: StatusCard(status: s)));

void main() {
  setUp(() => AttitudeStore.instance.clear());

  testWidgets('服务端 liked=true 时点赞图标就是实心红（回归：曾写死 false）', (tester) async {
    await tester.pumpWidget(_wrap(_status(liked: true, likes: 3)));

    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up_outlined), findsNothing);
    final icon = tester.widget<Icon>(find.byIcon(Icons.thumb_up));
    expect(icon.color, const Color(0xFFE6162D));
    expect(find.text('3'), findsWidgets);
  });

  testWidgets('服务端 liked=false 时是空心灰', (tester) async {
    await tester.pumpWidget(_wrap(_status(liked: false, likes: 0)));
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    expect(find.byIcon(Icons.thumb_up), findsNothing);
  });

  testWidgets('同 id 的新服务端数据会被采纳（详情页重新拉取后的场景）', (tester) async {
    await tester.pumpWidget(_wrap(_status(liked: false, likes: 0)));
    expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);

    // 父级换成服务端新值（同一 id）：必须同步，否则会停在旧状态
    await tester.pumpWidget(_wrap(_status(liked: true, likes: 4)));
    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.text('4'), findsWidgets);
  });

  testWidgets('本机覆盖层让同一条微博的其它副本一致（点赞后返回列表）', (tester) async {
    AttitudeStore.instance.set('100', liked: true, likes: 9);
    await tester.pumpWidget(_wrap(_status(liked: false, likes: 0)));

    expect(find.byIcon(Icons.thumb_up), findsOneWidget);
    expect(find.text('9'), findsWidgets);
  });
}
