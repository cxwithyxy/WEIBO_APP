import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../pages/video_player_page.dart';

/// 列表里的视频封面（封面图 + 播放按钮 + 时长角标）。
///
/// 交互约定（用户明确要求）：
///  - **点封面或播放按钮 = 进全屏播放器播放**；
///  - 点卡片其它区域仍然进详情页。
///
/// 这里用一个 `GestureDetector(behavior: opaque)` 把**整块封面**都变成播放热区，
/// 它嵌在卡片的 `InkWell` 内部 —— Flutter 手势竞技场里内层 recognizer 胜出，
/// 所以这块区域不会触发卡片的 `onTap`，而卡片其它区域照常进详情。
///
/// 封面加载沿用全屏看图的策略：**先查磁盘缓存，命中就直接挂图、不闪占位图**。
class VideoCover extends StatelessWidget {
  const VideoCover({
    super.key,
    required this.coverUrl,
    required this.onPlay,
    this.durationSecs,
    this.aspectRatio = 16 / 9,
  });

  final String? coverUrl;
  final VoidCallback onPlay;
  final int? durationSecs;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPlay,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _CoverImage(url: coverUrl),
              // 压暗一点，保证白色播放按钮在浅色封面上也看得清
              const DecoratedBox(
                decoration: BoxDecoration(color: Color(0x33000000)),
              ),
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: Color(0x66000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
              if (durationSecs != null && durationSecs! >= 0)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0x99000000),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      videoDurationLabel(durationSecs!),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 封面图：**缓存命中就不挂占位图**（否则会「先灰一下再跳图」）。
class _CoverImage extends StatelessWidget {
  const _CoverImage({required this.url});

  final String? url;

  static const _fallback = ColoredBox(
    color: Color(0xFF2A2A2A),
    child: Center(
      child: Icon(Icons.movie_outlined, color: Colors.white38, size: 34),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null || u.isEmpty) return _fallback;
    return FutureBuilder<FileInfo?>(
      // 先查一下封面是否已在磁盘缓存
      future: DefaultCacheManager().getFileFromCache(u),
      builder: (context, snap) {
        // 还没查完 → 用深色底顶着，不闪占位图
        if (snap.connectionState != ConnectionState.done) {
          return const ColoredBox(color: Color(0xFF2A2A2A));
        }
        final cached = snap.data != null;
        return CachedNetworkImage(
          imageUrl: u,
          fit: BoxFit.cover,
          // 命中缓存 → 不挂占位图，直接呈现封面
          placeholder: cached
              ? null
              : (_, _) => const ColoredBox(color: Color(0xFF2A2A2A)),
          errorWidget: (_, _, _) => _fallback,
        );
      },
    );
  }
}

/// 秒 → `mm:ss`（超过 1 小时给 `h:mm:ss`）
String videoDurationLabel(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 打开全屏播放器页。
///
/// 必须传 [mid]：播放器要靠它查本地缓存、并在命中不了时刷新已过期的直链。
void openVideoPlayer(
  BuildContext context, {
  required String url,
  String? mid,
  String? cover,
  String? title,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          VideoPlayerPage(url: url, mid: mid, cover: cover, title: title),
    ),
  );
}
