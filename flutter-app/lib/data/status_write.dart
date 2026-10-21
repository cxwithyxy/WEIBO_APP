import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import 'attitude.dart';
import 'cache.dart';

/// 取单条微博的最新响应原文（生产实现 = `/ajax/statuses/show`）。
typedef StatusRawFetcher = Future<StatusRawDto> Function(String mid);

/// 判断一次重拉是否已经「反映了本次写入」。
typedef StatusWriteCheck = bool Function(StatusDto status);

Future<StatusRawDto> _fetchFromNetwork(String mid) => api.statusDetailRaw(mid: mid);

/// 刷新单条微博缓存的**核心逻辑**（网络/文件 IO 全部注入，便于单测）。
///
/// 关键点：**读后写不保证立即可见**。实测：App 内 `setLike` 返回 `ok:1` 后，
/// 紧接着的 `statuses/show` 仍可能返回点赞前的旧值（随后再读才对）。所以不能
/// 「重拉一次就写盘」，否则会把旧真相覆盖进缓存/覆盖层，看起来又像「赞没生效」。
///
/// 判定「已反映本次写入」的规则：
///  - 调用方给了 [expect]（如「liked 必须为 true」）→ 用它；
///  - 否则退化为「原文与刷新前不同」；
///  - 不满足就隔 [retryDelay] 重拉，最多 [attempts] 次。
///
/// 结果：
///  - 拿到并确认新原文 → `save(raw)`，并把服务端状态交给 `applyServerState`；
///  - 任何一步失败（网络错、空响应、重拉始终旧、落盘失败）→ `remove()` 删掉旧缓存，
///    绝不让旧数据继续骗下一个读它的页面。
///
/// 永不抛异常：这是写成功后的收尾动作。
Future<void> syncStatusCache({
  required Future<StatusRawDto> Function() fetch,
  required Future<bool> Function(String raw) save,
  required Future<void> Function() remove,
  String? beforeRaw,
  StatusWriteCheck? expect,
  void Function(StatusDto? status)? applyServerState,
  int attempts = 4,
  Duration retryDelay = const Duration(milliseconds: 300),
}) async {
  bool reflectsWrite(StatusRawDto r) {
    if (r.raw.trim().isEmpty) return false;
    if (expect != null) return r.status != null && expect(r.status!);
    return beforeRaw == null || r.raw != beforeRaw;
  }

  try {
    var r = await fetch();
    var tries = 1;
    while (!reflectsWrite(r) && tries < attempts) {
      await Future<void>.delayed(retryDelay);
      r = await fetch();
      tries++;
    }
    if (r.raw.trim().isEmpty) {
      throw StateError('statuses/show 返回空原文');
    }
    if (!reflectsWrite(r)) {
      throw StateError('重拉 $tries 次仍是写入前的旧值');
    }
    if (!await save(r.raw)) {
      throw StateError('缓存落盘失败');
    }
    applyServerState?.call(r.status);
    final s = r.status;
    debugPrint(
      '[status-write] 缓存已刷新（第 $tries 次）'
      '${s == null ? '（原文已存，解析失败）' : ' liked=${s.liked} likes=${s.likes} comments=${s.comments} reposts=${s.reposts}'}',
    );
  } catch (e) {
    await remove();
    debugPrint('[status-write] 刷新失败，已删除旧缓存: $e');
  }
}

/// 生产入口：重拉网络 + 真实文件缓存，并把服务端点赞状态同步进 [AttitudeStore]。
Future<void> refreshStatusCache(
  String mid, {
  StatusRawFetcher? fetch,
  StatusWriteCheck? expect,
  int attempts = 4,
}) async {
  final beforeRaw = await StatusCache.load(mid);
  debugPrint('[status-write] 开始刷新缓存 mid=$mid（重拉 statuses/show）');
  return syncStatusCache(
    fetch: () => (fetch ?? _fetchFromNetwork)(mid),
    save: (raw) => StatusCache.save(mid, raw),
    remove: () => StatusCache.remove(mid),
    beforeRaw: beforeRaw,
    expect: expect,
    attempts: attempts,
    applyServerState: (s) {
      if (s != null) {
        AttitudeStore.instance.set(mid, liked: s.liked, likes: s.likes);
      }
    },
  );
}

/// 「针对单条微博」写操作的**统一入口**：写成功后刷新这条微博的缓存。
///
/// `action()` 正常返回即代表写成功 —— core 的 `check_mutation` 已判定过 `ok`
/// （部分接口不返回 ok 的也兼容），HTTP 200 但 `ok:0`（如重复点赞）会变成异常，
/// 所以这里**不是**裸看 HTTP 200。
///
/// [expect] 描述「写入完成后服务端应满足什么」，用于对抗读后写延迟；
/// 成功后异步触发刷新：**不 await**，不影响「点赞成功」的反馈；[refreshStatusCache]
/// 内部已兜底（失败删缓存）并打日志，不会静默吞掉。
Future<void> mutateStatus(
  String mid,
  Future<void> Function() action, {
  StatusWriteCheck? expect,
  Future<void> Function(String mid)? refresh,
}) async {
  await action();
  unawaited(refresh != null ? refresh(mid) : refreshStatusCache(mid, expect: expect));
}
