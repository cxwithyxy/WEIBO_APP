/// 未读「穿越判定」与未读集的**纯逻辑**。
///
/// 规则（需求方 2026-10-23 修订）：
///
/// > 新微博必须被我**从中线推过去**才算读。
///
/// 也就是**穿越式**，不是「只要在中线以上就算读」：
///
///  1. 中线 = 视口高度 / 2；
///  2. 滚动时，某条标题从「中线以下」→「中线以上」（`prev >= 0 && now < 0`）
///     那一下才算已读；
///  3. **首次观测到就已经在中线以上的不算读** —— 例如下拉刷新后新微博插在
///     顶部，它们一进来就在中线以上、从没被推过，必须保持未读（cx 要的就是
///     一眼看出哪些是新的）；
///  4. 兜底（需求方指定）：那些「一开始就在中线以上」的条目，当它被滚出屏幕
///     顶部（卡片底边 < 0）时也算已读 —— 否则它永远不可能完成「从下往上穿越」，
///     绿点会一直挂着；
///  5. 加载 / 刷新 / 翻页 / 缓存还原时一律不判定（刚进来的都是未读）。
///
/// 坐标系：`prevTitleY` / `nowTitleY` 是「标题 y − 中线」的值，**负 = 中线以上**；
/// `itemBottomY` 是卡片底边的视口坐标，**< 0 = 完全滚出屏幕顶部**。
library;

/// 卡片顶边 → 标题的估算偏移（像素）。
///
/// `StatusCard` 外层 `Padding` 顶部 12px，头部行第一行就是用户名/标题，
/// 所以标题顶边 ≈ 卡片顶边 + 12。**这是估算**，不追求像素级精确：
/// 判定只看「标题相对中线的正负」，一个常数偏移不改变穿越语义。
const double kStatusTitleOffset = 12.0;

/// 本次滚动采样中，「标题穿越中线」或「滚出屏幕顶部」而被标为已读的 id。
///
/// - [prevTitleY]：上一次采样里 id → 标题相对中线的 y（负 = 中线以上）；
/// - [nowTitleY]：本次采样里 id → 标题相对中线的 y；
/// - [itemBottomY]：id → 卡片底边视口 y（< 0 即滚出顶部），可选。
///
/// 只对**本次采样里存在**（在 [nowTitleY] 中）的 id 判定；首次出现的 id
/// （[prevTitleY] 里没有）**一律不算读** —— 这是「一开始就在中线以上保持未读」
/// 的关键。边界：`prev == 0` 视为「在中线上/以下」，`now == 0` 不算「已过线」。
Set<String> crossedToRead({
  required Map<String, double> prevTitleY,
  required Map<String, double> nowTitleY,
  Map<String, double>? itemBottomY,
}) {
  final out = <String>{};
  nowTitleY.forEach((id, now) {
    if (id.isEmpty) return;
    // 1) 从下往上穿越（prev >= 0 且 now < 0）。首次出现（prev 缺失）不算。
    final prev = prevTitleY[id];
    if (prev != null && prev >= 0 && now < 0) {
      out.add(id);
      return; // 已读，无需再看兜底
    }
    // 2) 兜底：被用户推着滚出屏幕顶部。
    final bottom = itemBottomY?[id];
    if (bottom != null && bottom < 0) out.add(id);
  });
  return out;
}

// ------------------------------------------------------------------ 未读集

/// 加入未读（新加载的算未读）。空 id 忽略；已有的不重复。
Set<String> unreadAddAll(Set<String> current, Iterable<String> ids) {
  final out = Set<String>.of(current);
  for (final id in ids) {
    if (id.isNotEmpty) out.add(id);
  }
  return out;
}

/// 标某条为已读。不在集合里就原样返回。
Set<String> unreadMarkRead(Set<String> current, String id) {
  if (id.isEmpty || !current.contains(id)) return current;
  return Set<String>.of(current)..remove(id);
}

/// 批量标已读。
Set<String> unreadMarkReadAll(Set<String> current, Iterable<String> ids) {
  if (current.isEmpty) return current;
  final out = Set<String>.of(current);
  for (final id in ids) {
    out.remove(id);
  }
  return out;
}

/// 剪枝：只保留 [present] 里还存在的未读 id（防无上限膨胀）。
///
/// ⚠️ [present] 为空、或全是空 id 时**原样返回**，绝不当作「全都不存在」而清空：
/// 解析异常 / 列表尚未就绪时可能拿到空 id，一刀清掉会让绿点全丢。
Set<String> unreadRetain(Set<String> current, Set<String> present) {
  if (current.isEmpty) return current;
  final real = present.where((id) => id.isNotEmpty).toSet();
  if (real.isEmpty) return current;
  final out = current.where(real.contains).toSet();
  return out.length == current.length ? current : out;
}
