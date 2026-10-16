/// 「上次刷到这里」标记的**位置计算**。
///
/// 单独拎出来是因为这里踩过两个坑，两处都必须靠测试锁住：
///
///  1. **不能拿 id 大小判断「深浅」**。关注流里会夹着**置顶微博**
///     （id 很小、却排在最前面），一旦用 id 比较，标记就会被置顶那条
///     钉死、之后永远不再推进 —— 真机上表现为「标记一直挂在顶部」。
///     所以「深浅」一律用**列表下标**判断（见 timeline_page 的 `_deepestIndex`）。
///
///  2. 锚点那条**不在当前列表里**时，仍要把标记插到「本该在的位置」，
///     方向别写反（见 `markerInsertIndex`）。
library;

/// 微博 id 排序用：`a` 是否比 `b` 更早（更旧）。
///
/// id 是 19 位以内的数字串，会超 int64 —— 必须用 BigInt。
/// 解析失败一律当「不比它更旧」（不猜）。
bool isOlderId(String a, String b) {
  try {
    return BigInt.parse(a) < BigInt.parse(b);
  } catch (_) {
    return false;
  }
}

/// 「你上次刷到这里」分割条该插在下标几。
///
/// [idsNewestFirst]：当前展示序列的微博 id，**新 → 旧**（和列表顺序一致）
/// [anchorId]：锚点（上次读到的位置）
///
/// 返回 `0..idsNewestFirst.length`，表示分割条插在该下标**之前**；
/// 等于 `length` 就是插到最末尾。
///
/// 判据：列表是「新→旧」，锚点应落在**第一条比它更旧**的条目之前 ——
/// 这样它上面的都更新（未读）、下面的都更旧（已读过）。
///
/// ⚠️ 会先**跳过开头的逆序段**：关注流第一页页首常插一条**置顶微博**，
///    它 id 极小却排在最前面。不跳过的话，单看 id 会得出「整页都比它新」
///    → 标记被插到列表顶部（真机上的「标记一直挂在顶部」就是这个）。
int markerInsertIndex(List<String> idsNewestFirst, String anchorId) {
  var start = 0;
  while (start + 1 < idsNewestFirst.length &&
      !isOlderId(idsNewestFirst[start + 1], idsNewestFirst[start])) {
    start++;
  }
  for (var i = start; i < idsNewestFirst.length; i++) {
    if (isOlderId(idsNewestFirst[i], anchorId)) return i;
  }
  return idsNewestFirst.length;
}
