/// 把服务端重新拉到的「第一页」合并进**已加载的有序列表**
/// （stale-while-revalidate 的更新语义）。
///
/// 规则：
///  - `fresh` 里 id 未出现过的 → 视为新项，按其在 `fresh` 中的先后**插到顶部**；
///  - `fresh` 里已存在的 → 用新数据**原地更新**（保位置、不重复出现）；
///  - `existing` 里不在 `fresh` 的（已翻过的后续页、或服务端这次没返回的）
///    **原样保留**，后续页顺序不变；
///  - 全程按 id 去重；`fresh` 内部重复只认第一条。
///
/// 纯函数：不依赖 widget、不修改入参。列表为空/全重复/服务端减少等边界都安全。
List<T> mergeFirstPage<T>({
  required List<T> existing,
  required List<T> fresh,
  required String Function(T) idOf,
}) {
  // 旧列表里每个 id 第一次出现的位置（重复 id 以第一条为准）
  final indexById = <String, int>{};
  for (var i = 0; i < existing.length; i++) {
    final id = idOf(existing[i]);
    if (id.isNotEmpty) indexById.putIfAbsent(id, () => i);
  }

  final result = List<T>.of(existing);
  final newOnes = <T>[];
  final handled = <String>{};

  for (final f in fresh) {
    final id = idOf(f);
    if (id.isNotEmpty && !handled.add(id)) continue; // fresh 内部重复
    final idx = id.isEmpty ? null : indexById[id];
    if (idx != null) {
      result[idx] = f; // 已存在 → 原地更新
    } else {
      newOnes.add(f); // 新项 → 稍后置顶
    }
  }

  if (newOnes.isEmpty) return result;
  return [...newOnes, ...result];
}
