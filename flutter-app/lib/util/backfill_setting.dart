/// 设置项「每次刷新最多补拉页数」的纯逻辑：边界、时长换算、文案。
///
/// 抽出来是为了：① 边界只在一处 clamp，脏配置/手改配置进不来；
/// ② 文案里的「约几小时」不在 UI 里散落魔法数。
library;

/// 补拉一页大约花掉的时间（分钟）。
///
/// **来自设备实测，不是拍脑袋**：MuMu + 真实关注流，2026-10-23 下午
/// 15 页补拉覆盖 `15:21 → 08:54` = 6.45h，即 `6.45h / 15 ≈ 25.8min/页`，
/// 取整成 **26 分钟**（略偏保守，宁可把时长估长、别让用户以为一拉就完）。
const int kMinutesPerPage = 26;

/// 设置项默认值：30 页。
///
/// 30 × 26min ≈ 13h，能盖住 cx 报的 8:00→15:00 七小时断档并留一倍余量；
/// 他最初提的 10 页只有 ≈4.3h，比断档本身还短，等于没修，故不采用。
const int kDefaultMaxBackfillPages = 30;

/// 允许范围：小于 5 页基本无意义，大于 120 页（≈52h）容易触发风控。
const int kMinMaxBackfillPages = 5;
const int kMaxMaxBackfillPages = 120;

/// 把任意 int 收进 [kMinMaxBackfillPages, kMaxMaxBackfillPages]。
///
/// 读取旧配置、手改 SharedPreferences、滑杆回调都过这一道，
/// 保证 App 不会因为脏数据变成「0 页」或「无限拉」。
int clampMaxBackfillPages(int v) =>
    v.clamp(kMinMaxBackfillPages, kMaxMaxBackfillPages);

/// 该页数大约能覆盖多少小时（四舍五入到整小时）。
///
/// 例：30 → 13，10 → 4，120 → 52。
int backfillApproxHours(int pages) =>
    (clampMaxBackfillPages(pages) * kMinutesPerPage / 60).round();

/// 设置页副标题 / 对话框里的展示文案，例：`30 页 · 约 13 小时`。
///
/// 入参先 clamp，所以即使上游给了 0 也能得到合法文案。
String backfillPagesLabel(int pages) {
  final p = clampMaxBackfillPages(pages);
  return '$p 页 · 约 ${backfillApproxHours(p)} 小时';
}
