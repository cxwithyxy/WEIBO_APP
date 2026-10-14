import 'package:flutter/material.dart';

import '../src/rust/api/error.dart';

/// 平台无关的 int64 展示 Helper。
///
/// FRB 把 Rust 的 `i64` 映射成 `PlatformInt64`（Android 上是 `int`、Web 上是 `BigInt`）。
/// 统一走字符串转换，避免平台差异。
String p64(Object? v) => v?.toString() ?? '0';

int p64Int(Object? v) => int.tryParse(v?.toString() ?? '') ?? 0;

/// 大数格式化：12345 → 1.2万；123456789 → 1.2亿
String fmtCount(int n) {
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return '$n';
}

/// 把异常转成可读文本。
///
/// `WeiboFailure` 是桥接层专门定义的可读错误（见 rust/src/api/error.rs）——
/// core 的 `WeiboError` 是外部类型，FRB 只会生成 opaque 句柄，Dart 读不到原因。
String describeError(Object e) {
  if (e is WeiboFailure) {
    return e.message.isEmpty ? e.kind : e.message;
  }
  return e.toString();
}

/// 加载失败展示（带重试）。
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 44, color: Colors.orange),
            const SizedBox(height: 12),
            SelectableText(
              describeError(error),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 空状态
class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.text, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 44, color: Colors.grey.shade400),
          const SizedBox(height: 10),
          Text(text, style: TextStyle(color: Colors.grey.shade600, fontSize: 14)),
        ],
      ),
    );
  }
}

/// 列表底部「加载中 / 没有更多」
class FooterHint extends StatelessWidget {
  const FooterHint({super.key, required this.loading, required this.hasMore});

  final bool loading;
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text('没有更多了', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

/// 九宫格配图。点开进入查看器。
class ImageGrid extends StatelessWidget {
  const ImageGrid({super.key, required this.urls, this.small = false});

  final List<String> urls;

  /// 转发卡片里用更小的图
  final bool small;

  @override
  Widget build(BuildContext context) {
    if (urls.isEmpty) return const SizedBox.shrink();
    final shown = urls.length > 9 ? urls.sublist(0, 9) : urls;
    final single = shown.length == 1;

    return LayoutBuilder(
      builder: (context, c) {
        final cols = single ? 1 : 3;
        final spacing = 4.0;
        final side = small ? 72.0 : (c.maxWidth - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (var i = 0; i < shown.length; i++)
              GestureDetector(
                onTap: () => openImageViewer(context, shown, i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    width: single ? (small ? 140 : c.maxWidth) : side,
                    height: single ? (small ? 100 : 180) : side,
                    child: _Thumb(url: shown[i]),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return Container(
          color: Colors.grey.shade200,
          child: const Center(
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        );
      },
      errorBuilder: (_, _, _) => Container(
        color: Colors.grey.shade200,
        child: Icon(Icons.broken_image_outlined, color: Colors.grey.shade500),
      ),
    );
  }
}

/// 全屏图片查看器（可缩放、可翻页）。
void openImageViewer(BuildContext context, List<String> urls, int index) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ImageViewer(urls: urls, initial: index),
    ),
  );
}

class _ImageViewer extends StatefulWidget {
  const _ImageViewer({required this.urls, required this.initial});

  final List<String> urls;
  final int initial;

  @override
  State<_ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<_ImageViewer> {
  late final PageController _controller = PageController(initialPage: widget.initial);
  late int _index = widget.initial;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.urls.length}'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: Image.network(
              widget.urls[i],
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(
                Icons.broken_image_outlined,
                color: Colors.white54,
                size: 64,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「已登录才可用」的提示（关注/我的 等页面用）
class NeedLoginView extends StatelessWidget {
  const NeedLoginView({super.key, required this.onLogin});

  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.account_circle_outlined, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('需要先登录', style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onLogin, child: const Text('去登录')),
        ],
      ),
    );
  }
}
