import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../data/video_cache.dart';
import '../src/rust/api/weibo.dart' as api;
import '../util/video_url.dart';
import '../widgets/common.dart';

/// 全屏视频播放器页。
///
/// **为什么要 mid**：信息流缓存里存的是几天前的响应原文，视频直链里的
/// `Expires=` 早已过期 → CDN 403 → `video_player` 报 `Source error`
/// （详情页每次现拉 `statuses/show`，所以能播）。本页在**本地缓存未命中**时
/// 先用 `statusDetail(mid)` 换一条新鲜直链，再下载/播放。
///
/// 播放顺序：
///  1. `files/video/<mid>.mp4` 命中 → 直接本地播，**零网络**；
///  2. 未命中 → `statusDetail(mid)` 刷新 URL → 下载到 `.part` → rename → 本地播；
///  3. 下载失败 → 回退在线流式播放新鲜 URL，并明确提示「未缓存，直接播放」；
///  4. 刷新失败 → 回退列表传入的旧 URL（过期时如实提示，可重试）。
///
/// 该直链是 **http://**（明文），必须靠 `network_security_config.xml`
/// 白名单放行；视频文件下载走 Dart 的 HttpClient（同样受该白名单约束）。
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.url,
    this.mid,
    this.cover,
    this.title,
  });

  /// 列表传入的视频直链（可能已过期，仅作兜底）
  final String url;

  /// 微博 mid —— 本地缓存的键、刷新 URL 的依据
  final String? mid;

  /// 封面（加载/下载/报错时垫底，避免纯黑）
  final String? cover;

  final String? title;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

enum _Stage { preparing, downloading, playing, failed }

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  Object? _error;
  bool _ready = false;
  _Stage _stage = _Stage.preparing;

  /// 非致命提示（回退旧链接 / 未缓存直接播放 / 下载失败原因）
  String? _notice;
  bool _noticeRetryable = false;

  bool _fromCache = false;
  int _received = 0;
  int? _total;

  /// 每次 `_init` +1；异步回来的旧任务据此丢弃（重试/退出页面时）。
  int _run = 0;
  bool _disposed = false;
  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    _controller?.dispose();
    super.dispose();
  }

  bool _alive(int run) => mounted && !_disposed && run == _run;

  Future<void> _init() async {
    final run = ++_run;
    setState(() {
      _error = null;
      _ready = false;
      _notice = null;
      _noticeRetryable = false;
      _fromCache = false;
      _received = 0;
      _total = null;
      _stage = _Stage.preparing;
    });

    final old = _controller;
    _controller = null;
    await old?.dispose();
    if (!_alive(run)) return;

    final mid = widget.mid?.trim() ?? '';

    // 1) 本地缓存优先：命中就直接播，不联网、不刷新 URL（URL 轮换无关）。
    if (mid.isNotEmpty) {
      final hit = await VideoCache.lookup(mid);
      if (!_alive(run)) return;
      if (hit != null) {
        _fromCache = true;
        await _playFile(hit, run);
        return;
      }
    }

    // 2) 未命中 → 拉详情换新鲜 URL（列表里的 URL 可能已过期几天）。
    String? fresh;
    String? refreshProblem;
    if (mid.isNotEmpty) {
      try {
        final detail = await api.statusDetail(mid: mid);
        final u = detail.videoUrl;
        if (u != null && u.trim().isNotEmpty) {
          fresh = u;
          if (!isVideoUrlFresh(u)) {
            refreshProblem = '详情返回的链接也临近过期';
          }
        } else {
          refreshProblem = '该微博已没有视频';
        }
      } catch (e) {
        refreshProblem = '刷新视频地址失败：${describeError(e)}';
      }
    } else {
      refreshProblem = '缺少 mid，无法刷新地址';
    }
    if (!_alive(run)) return;

    final useUrl = (fresh != null && fresh.isNotEmpty) ? fresh : widget.url;
    if (useUrl.isEmpty) {
      setState(() {
        _stage = _Stage.failed;
        _error = const VideoCacheException('没有可播放的视频地址');
        _notice = refreshProblem;
      });
      return;
    }

    // 用的是列表旧 URL（刷新失败/无视频）→ 如实提示，可能过期。
    if (fresh == null || fresh.isEmpty) {
      final oldFresh = isVideoUrlFresh(widget.url);
      _notice = [
        ?refreshProblem,
        '正在使用列表里的旧链接${oldFresh ? '' : '（可能已过期）'}',
      ].join('，');
      _noticeRetryable = true;
    } else if (refreshProblem != null) {
      _notice = refreshProblem;
      _noticeRetryable = true;
    }

    // 3) 按 mid 下载到 files/video/<mid>.mp4（.part → rename）。
    if (mid.isNotEmpty) {
      setState(() => _stage = _Stage.downloading);
      try {
        final f = await VideoCache.download(
          mid: mid,
          url: useUrl,
          onProgress: (received, total) => _onProgress(run, received, total),
          isCancelled: () => !_alive(run),
        );
        if (!_alive(run)) return;
        _fromCache = true;
        await _playFile(f, run);
        return;
      } on VideoCacheCancelled {
        // 页面已退出/重试：静默丢弃本次下载（.part 已由缓存层删除）。
        return;
      } catch (e) {
        if (!_alive(run)) return;
        // 4) 下载失败 → 用新鲜 URL 在线流式播，不装作已缓存。
        _notice = [
          '未缓存，直接播放',
          if (fresh != null) '（下载失败：${describeError(e)}）',
        ].join();
        _noticeRetryable = true;
      }
    } else {
      _notice = '未缓存，直接播放（缺少 mid，无法按条缓存）';
    }

    if (!_alive(run)) return;
    await _playNetwork(useUrl, run);
  }

  void _onProgress(int run, int received, int? total) {
    if (!_alive(run)) return;
    final now = DateTime.now();
    final finished = total != null && received >= total;
    // 节流：每 120ms 一次，避免大文件下载时每 8KB setState。
    if (!finished &&
        now.difference(_lastProgressAt) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastProgressAt = now;
    setState(() {
      _received = received;
      _total = total;
    });
  }

  Future<void> _playFile(File file, int run) async {
    if (!_alive(run)) return;
    final c = VideoPlayerController.file(file);
    await _initController(c, run);
  }

  Future<void> _playNetwork(String url, int run) async {
    if (!_alive(run)) return;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      setState(() {
        _stage = _Stage.failed;
        _error = const VideoCacheException('视频地址无法解析');
      });
      return;
    }
    final c = VideoPlayerController.networkUrl(uri);
    await _initController(c, run);
  }

  Future<void> _initController(VideoPlayerController c, int run) async {
    _controller = c;
    try {
      await c.initialize().timeout(const Duration(seconds: 30));
      if (!_alive(run)) {
        await c.dispose();
        return;
      }
      await c.setLooping(true);
      setState(() {
        _ready = true;
        _stage = _Stage.playing;
      });
      await c.play();
    } catch (e) {
      try {
        await c.dispose();
      } catch (_) {}
      if (!_alive(run)) return;
      if (identical(_controller, c)) _controller = null;
      setState(() {
        _error = e;
        _stage = _Stage.failed;
        _noticeRetryable = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.title ?? '视频',
              style: const TextStyle(fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
            if (_stage == _Stage.playing)
              Text(
                _fromCache ? '本地缓存 · 零网络' : '在线播放 · 未缓存',
                style: const TextStyle(fontSize: 10.5, color: Colors.white60),
              ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_stage == _Stage.failed) return _errorView();

    final c = _controller;
    if (_stage == _Stage.playing && _ready && c != null) {
      return Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: Center(
                  child: GestureDetector(
                    // 点画面：播放/暂停
                    onTap: _togglePlay,
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio == 0
                          ? 16 / 9
                          : c.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(c),
                          // 暂停时给一个明显的播放按钮
                          ValueListenableBuilder<VideoPlayerValue>(
                            valueListenable: c,
                            builder: (context, v, _) {
                              if (v.isPlaying) return const SizedBox.shrink();
                              return _BigPlayButton(onTap: _togglePlay);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _controls(c),
            ],
          ),
          if (_notice != null)
            Positioned(
              top: 8,
              left: 8,
              right: 8,
              child: _NoticeBar(
                text: _notice!,
                onRetry: _noticeRetryable ? _init : null,
              ),
            ),
        ],
      );
    }

    return _loadingView();
  }

  Widget _loadingView() {
    final downloading = _stage == _Stage.downloading;
    final percent = (_total != null && _total! > 0)
        ? (_received / _total!).clamp(0.0, 1.0)
        : null;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (widget.cover != null && widget.cover!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: CachedNetworkImage(
                  imageUrl: widget.cover!,
                  width: 220,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            const SizedBox(height: 20),
            if (downloading) ...[
              SizedBox(
                width: 260,
                child: LinearProgressIndicator(
                  value: percent,
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFE6162D)),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                percent == null
                    ? '正在缓存视频… ${formatBytes(_received)}'
                    : '正在缓存视频… ${(percent * 100).toStringAsFixed(0)}%'
                          '（${formatBytes(_received)} / ${formatBytes(_total!)}）',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              const Text(
                '下载完成后直接从本地播放',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ] else ...[
              const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 14),
              const Text(
                '正在获取最新视频地址…',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 18),
              _NoticeBar(
                text: _notice!,
                onRetry: _noticeRetryable ? _init : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.orange),
            const SizedBox(height: 12),
            const Text(
              '视频加载失败',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 8),
            SelectableText(
              describeError(_error ?? '未知错误'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
            if (_notice != null) ...[
              const SizedBox(height: 14),
              _NoticeBar(
                text: _notice!,
                onRetry: _noticeRetryable ? _init : null,
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _init,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      // 播完后再点 → 从头发起
      if (c.value.position >= c.value.duration) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
    }
    if (mounted) setState(() {});
  }

  Widget _controls(VideoPlayerController c) {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black,
        padding: const EdgeInsets.fromLTRB(6, 4, 12, 8),
        child: Row(
          children: [
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) => IconButton(
                icon: Icon(
                  v.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.white,
                ),
                tooltip: v.isPlaying ? '暂停' : '播放',
                onPressed: _togglePlay,
              ),
            ),
            Expanded(
              // allowScrubbing: true → 进度条可拖
              child: VideoProgressIndicator(
                c,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                colors: const VideoProgressColors(
                  playedColor: Color(0xFFE6162D),
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: c,
              builder: (context, v, _) => Text(
                '${_fmt(v.position)} / ${_fmt(v.duration)}',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 页面内的「如实提示」条：回退旧链接 / 未缓存直接播 / 下载失败。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
      decoration: BoxDecoration(
        color: const Color(0xCC3A2A00),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0x66FFB300)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline,
              size: 15,
              color: Colors.orangeAccent,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFFFE0B2),
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: Colors.orangeAccent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 11.5)),
            ),
        ],
      ),
    );
  }
}

class _BigPlayButton extends StatelessWidget {
  const _BigPlayButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.play_arrow, color: Colors.white, size: 40),
      ),
    );
  }
}

/// 秒 → `mm:ss` / `h:mm:ss`
String _fmt(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
