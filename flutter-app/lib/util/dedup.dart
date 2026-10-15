/// 按 id 去重，保留**首次出现**的顺序。
///
/// 为什么客户端必须自己做 —— 微博信息流是**动态**的：
///
///  1. 关注流 / 用户页 / 我的页 / 搜索 / 转发 / 评论 都用 `page=N` 翻页。
///     两次请求之间若有新内容插入，整个窗口会后移，**相邻页的边界必然重复**。
///  2. 首页流虽然用游标（`since_id` = max_id），但流里混了推荐内容，
///     推荐项每次请求都可能被重新挑中，也不能保证严格不重叠。
///  3. 同一页内部也可能重复（置顶 + 原条目）。
///
/// 服务端**不保证**跨页不重复，所以「去重」是客户端的责任，不是可选项。
///
/// [seen] 传同一个集合可在**多页 / 多批**之间累积去重；
/// 不传则只对本批生效（批内去重）。
///
/// 没有 id 的条目会**原样保留**（没法比较的东西不替服务端做决定）。
List<T> dedupById<T>(
  Iterable<T> items,
  String Function(T) idOf, {
  Set<String>? seen,
}) {
  final s = seen ?? <String>{};
  final out = <T>[];
  for (final it in items) {
    final id = idOf(it);
    if (id.isEmpty || s.add(id)) out.add(it);
  }
  return out;
}
