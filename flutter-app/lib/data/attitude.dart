import 'package:flutter/foundation.dart';

/// 一条微博「本机已知的点赞状态」。
@immutable
class Attitude {
  const Attitude({required this.liked, required this.likes});

  final bool liked;
  final int likes;
}

/// 点赞状态的**本机覆盖层**（按微博 id）。
///
/// 为什么需要它：
///  - 同一条微博会同时出现在首页、详情、我的、搜索等多个列表里，各自持有一份
///    `StatusDto` 副本。点一次赞若只改当前卡片，其它副本（尤其是**返回后的列表卡片**）
///    仍显示旧值，看起来就像「赞没生效」。
///  - 各列表不会因为一次点赞而重新拉取数据，所以只靠服务端数据同步不过来。
///
/// 这里只记录**本机写成功**过的状态；`StatusCard` 渲染时优先采用它，并监听变化，
/// 于是详情页点赞后返回列表能立即一致。它是纯内存的：杀进程重开后覆盖层为空，
/// 卡片回落到服务端的 `Status.liked`（`attitudes_status`），冷启动同样正确。
class AttitudeStore extends ChangeNotifier {
  AttitudeStore._();
  static final AttitudeStore instance = AttitudeStore._();

  final _byId = <String, Attitude>{};

  Attitude? operator [](String id) => _byId[id];

  void set(String id, {required bool liked, required int likes}) {
    _byId[id] = Attitude(liked: liked, likes: likes);
    notifyListeners();
  }

  /// 清空覆盖层。切换/退出账号时必须调用，否则上一条会话的点赞状态会串到新账号。
  void clear() {
    _byId.clear();
    notifyListeners();
  }
}
