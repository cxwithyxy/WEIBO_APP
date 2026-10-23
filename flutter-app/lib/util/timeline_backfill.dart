import '../src/rust/api/dto.dart';

/// 一次下拉刷新最多再往后补拉的页数（第一页不算）。
///
/// **数值来自实测，不是拍脑袋**：在 MuMu 上对真实关注流量过 ——
/// 16 页（第一页 + 15 页补拉）覆盖 `15:21 → 08:54`，即 **6.45h / 16 页 ≈ 24min/页**。
/// cx 报的场景是 8:00→15:00 七小时，旧上限 15 页只够 6.5h，**刚好差一点、修不干净**。
///
/// 取 60 页：60 × 24min ≈ **24h**（≈1500 条），给「隔一天没开 App」留量；
/// 同时仍是硬上限，防止服务端异常时无限拉。代价是页间必须限速（见
/// [kBackfillPageDelay]），否则 60 个 GET 连打容易触发风控。
///
/// ⚠️ 这只是**库默认值**（tests / 未传参的调用方）。App 实际用的是用户设置
/// `Settings.maxBackfillPages`（默认 30，范围 5..120），由 `refresh()` 每次现读传入。
const int kMaxBackfillPages = 60;

/// 补拉时每页之间的限速延时。
///
/// 60 页 × 120ms ≈ 7.2s 纯等待，换来的是「像人翻页而不是脚本扫接口」。
/// 由调用方在每页处理完后 `await Future.delayed(kBackfillPageDelay)`。
const Duration kBackfillPageDelay = Duration(milliseconds: 120);

/// 补拉循环**为什么停**。调用方据此判断「是接上了」还是「被上限截断」。
///
/// [connected] / [emptyPage] / [capReached] 由纯函数 [backfillStopReason] 判定；
/// [cursorEnd] / [failed] 依赖网络/游标，由 `refresh()` 在循环里判定。
enum BackfillStop {
  /// 已接上旧内容（id 命中，或时间区间已覆盖）—— 正常收工。
  connected,

  /// 本页为空 —— 服务端没有更旧的内容了。
  emptyPage,

  /// 触到页数上限就停了，**可能还差一截没接上**。调用方必须留下可见信号。
  capReached,

  /// 游标不再前进（home）/ 本页不足一页（following）—— 服务端翻到头了。
  cursorEnd,

  /// 补拉途中请求失败 —— 停止，但已拿到的内容保留。
  failed,
}

/// 一页时间线处理完后，还要不要继续往后（更旧方向）补拉？
///
/// 背景：下拉刷新时第一页只覆盖「最新的一小段」。若列表里本来就有旧缓存，
/// 第一页与旧内容之间会出现断层 —— 这个函数判断「断档接上了没有」，
/// 返回 `true` 表示还没接上、要继续拉。
///
/// 参数约定：
///  - [page]：**刚处理完的那一页**（新 → 旧）。第一页也会传进来判一次。
///  - [pagesFetched]：本次补拉**已经额外抓到的页数**（不含刷新第一页）。
///  - [knownIds]：刷新开始前就已有的 id 快照，循环中**不得变化** ——
///    否则本批新拉到的页会互相「命中」，一页都补不动。
///  - [newestKnownTime]：旧内容里最新一条的时间（同样是进循环前的快照）。
///  - [isFirstPage]：传进来的 [page] 是不是「刷新拉的那第一页」。
///    **第一页必须为 true**，原因见下（置顶微博的坑）。
///
/// 停止条件（任一命中即停，对应 cx 报的漏数据 bug）：
///  1. 本页为空 —— 服务端没内容了；
///  2. 本页出现 [knownIds] 里的 id —— **已经接上旧内容**（首选判据）；
///  3. 本页最旧一条的 time <= [newestKnownTime] —— **时间区间已覆盖**。
///     这是兜底：旧的最新那条可能已被删/被改，光等 id 永远等不到；
///     只要时间上已经重叠，中间就不可能有断层了；
///  4. [pagesFetched] >= [maxPages] —— 安全上限，绝不无限拉。
///
/// ⚠️ 为什么首屏要跳过条件 2：关注流/首页会把**置顶微博**放在第一页最前，
/// 而置顶那条 id 往往几天不变、必然躺在 [knownIds] 里。若首屏也按 id 判，
/// 刷新一进来就「命中置顶」→ 一页都不补，断档原样保留 —— 等于没修。
/// 首屏只按时间判断；真正的 id 命中留给后面的补拉页（置顶一般只在第一页）。
///
/// ⚠️ 「本页最旧一条」取的是**最后一条**（[page].last.time），不是全页最小值。
/// 原因同上：置顶微博时间往往很旧却排在最前，取 min 会用置顶那条的旧时间
/// 误判「已覆盖旧内容」而提前停。这些流按时间降序、置顶只在最前，所以最后
/// 一条才是真正的本页最旧。万一某页并非严格降序，用 last 偏保守（多补一页
/// 而不是漏数据），符合「宁可多拉不可漏」。
///
/// `StatusDto.time` 是 `YYYY/MM/DD HH:mm:SS` 定长格式，字典序 == 时间序，
/// 所以直接 `compareTo` 即可，不用解析成 DateTime。
/// 返回 `null` = 还没接上，继续补；非 null = 停止及原因。
///
/// 判定顺序（任一命中即返回）：
///  1. 空页 → [BackfillStop.emptyPage]；
///  2. id 命中 [knownIds] → [BackfillStop.connected]（首屏除外，见上）；
///  3. [page].last.time <= [newestKnownTime] → [BackfillStop.connected]（时间兜底）；
///  4. [pagesFetched] >= [maxPages] → [BackfillStop.capReached]（**要留信号**）。
///
/// 注意 3 排在 4 前面：如果最后一页已经接上，就不算「被上限截断」，
/// 不会误报 capReached。
BackfillStop? backfillStopReason({
  required Set<String> knownIds,
  required String newestKnownTime,
  required List<StatusDto> page,
  required int pagesFetched,
  int maxPages = kMaxBackfillPages,
  bool isFirstPage = false,
}) {
  // 1. 空页：没东西可判，停。
  if (page.isEmpty) return BackfillStop.emptyPage;

  // 2. id 命中：本页只要出现一个「旧内容里已有的 id」，就说明新旧接上了。
  //    注意允许本页还夹着新内容 —— 接上即停，该页新内容会一起并入列表。
  //    首屏除外：置顶微博会长期占据 knownIds，见函数头说明。
  if (!isFirstPage) {
    for (final s in page) {
      if (knownIds.contains(s.id)) return BackfillStop.connected;
    }
  }

  // 3. 时间覆盖兜底：本页最后一条（时间降序 → 本页最旧）与旧内容最新一条比。
  //    等于也停（`<=`）：同一时间点即视为重叠。
  final oldest = page.last.time;
  if (oldest.compareTo(newestKnownTime) <= 0) return BackfillStop.connected;

  // 4. 安全上限。
  if (pagesFetched >= maxPages) return BackfillStop.capReached;

  return null;
}

/// `backfillStopReason(...) == null` 的布尔包装（语义更直白，老调用方沿用）。
bool shouldContinueBackfill({
  required Set<String> knownIds,
  required String newestKnownTime,
  required List<StatusDto> page,
  required int pagesFetched,
  int maxPages = kMaxBackfillPages,
  bool isFirstPage = false,
}) =>
    backfillStopReason(
      knownIds: knownIds,
      newestKnownTime: newestKnownTime,
      page: page,
      pagesFetched: pagesFetched,
      maxPages: maxPages,
      isFirstPage: isFirstPage,
    ) ==
    null;

/// 把「本次刷新按新 → 旧顺序抓到的若干页」并到已有列表**前面**。
///
/// 结果顺序严格是：
/// `fetchedNewestFirst[0] + fetchedNewestFirst[1] + ... + existing`
///
/// 去重口径与 `dedupById` 一致：按 [idOf] 去重、**保留首次出现**（新的优先）；
/// 没有 id（空串）的条目原样保留。跨抓取页、以及抓取页对 [existing] 都会去重。
///
/// 为什么不逐页 `insertAll(0, ...)`：那样第 2 页会被插到第 1 页前面，顺序反转。
/// 这里一次性按顺序铺开，天然正确。
///
/// 纯函数：不依赖 widget、不修改入参。
List<T> mergeBackfillPages<T>({
  required List<T> existing,
  required List<List<T>> fetchedNewestFirst,
  required String Function(T) idOf,
}) {
  final seen = <String>{};
  final out = <T>[];

  void take(Iterable<T> items) {
    for (final it in items) {
      final id = idOf(it);
      if (id.isEmpty || seen.add(id)) out.add(it);
    }
  }

  for (final page in fetchedNewestFirst) {
    take(page);
  }
  take(existing);
  return out;
}
