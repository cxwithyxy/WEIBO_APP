import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../session.dart';
import '../src/rust/api/dto.dart';
import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';

/// 扫码登录页。
///
/// 流程（与原 Android 版一致）：
///   1. `authPrepare` 预热 cookie
///   2. `authCreateQr` 拿二维码（qrid + 图片）
///   3. 轮询 `authPoll`：waiting → scanned → confirmed
///   4. confirmed 后 `authComplete(url)` 吸收 cookie
///
/// 二维码约 3 分钟失效，过期后可重新获取。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.onLoggedIn});

  final VoidCallback? onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  QrSessionDto? _qr;
  String? _error;
  String _hint = '正在获取二维码…';
  bool _loading = true;
  bool _done = false;

  Timer? _timer;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _qr = null;
      _hint = '正在获取二维码…';
      _ticks = 0;
    });
    try {
      await api.authPrepare();
      final qr = await api.authCreateQr(size: 280);
      if (!mounted) return;
      setState(() {
        _qr = qr;
        _loading = false;
        _hint = '打开手机微博「扫一扫」并确认登录';
      });
      _timer = Timer.periodic(const Duration(milliseconds: 2500), (_) => _poll());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
  }

  Future<void> _poll() async {
    final qr = _qr;
    if (qr == null || _done) return;
    _ticks++;
    // 约 3 分钟（120 * 1.5s）没结果就提示过期
    if (_ticks > 80) {
      _timer?.cancel();
      if (mounted) setState(() => _hint = '二维码已过期，请重新获取');
      return;
    }
    try {
      final st = await api.authPoll(qrid: qr.qrid);
      if (!mounted) return;
      switch (st.state) {
        case QrStateDto.confirmed:
          _timer?.cancel();
          final url = st.url ?? '';
          await api.authComplete(url: url);
          await Session.instance.onLoggedIn();
          if (!mounted) return;
          setState(() {
            _done = true;
            _hint = '已登录';
          });
          widget.onLoggedIn?.call();
          break;
        case QrStateDto.scanned:
          setState(() => _hint = '已扫码，请在手机上点「确认登录」');
          break;
        case QrStateDto.expired:
          _timer?.cancel();
          setState(() => _hint = '二维码已过期，请重新获取');
          break;
        case QrStateDto.error:
          setState(() => _hint = st.message ?? '登录失败，请重试');
          break;
        case QrStateDto.waiting:
        case null:
          break;
      }
    } catch (e) {
      // 轮询过程中的偶发错误不打断流程
      if (mounted) setState(() => _hint = '等待扫码…（${describeError(e)}）');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('微博客户端')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_error != null)
                ErrorView(error: _error!, onRetry: _start)
              else ...[
                _qrBox(),
                const SizedBox(height: 16),
                Text(_hint, style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
                const SizedBox(height: 6),
                if (_loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新获取二维码'),
                ),
              ],
              const SizedBox(height: 28),
              const Divider(),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('扫码登录说明', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    _step('1', '打开手机上的「微博」App'),
                    _step('2', '点右上角「+」→ 扫一扫'),
                    _step('3', '对准上面的二维码'),
                    _step('4', '在手机上点「确认登录」'),
                    const SizedBox(height: 10),
                    Text(
                      '提示：二维码约 3 分钟失效，过期后点上方按钮重新获取。',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _qrBox() {
    final qr = _qr;
    return Container(
      width: 240,
      height: 240,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: qr == null
          ? const Center(child: CircularProgressIndicator())
          : _QrImage(url: qr.imageUrl),
    );
  }

  Widget _step(String n, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text('$n.', style: const TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// 二维码图片。服务端可能给 URL，也可能给 data:image/...;base64,...
class _QrImage extends StatelessWidget {
  const _QrImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.startsWith('data:image')) {
      final i = url.indexOf(',');
      if (i > 0) {
        try {
          final bytes = base64Decode(url.substring(i + 1));
          return Image.memory(bytes, fit: BoxFit.contain);
        } catch (_) {
          // 落到下面的兜底
        }
      }
      return const Center(child: Icon(Icons.qr_code_2, size: 120));
    }
    return Image.network(
      url,
      fit: BoxFit.contain,
      loadingBuilder: (c, child, p) =>
          p == null ? child : const Center(child: CircularProgressIndicator()),
      errorBuilder: (_, _, _) => const Center(child: Icon(Icons.qr_code_2, size: 120)),
    );
  }
}
