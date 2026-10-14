import 'package:flutter/material.dart';

import '../src/rust/api/weibo.dart' as api;
import '../widgets/common.dart';

/// 发微博。纯文字（与原 Android 版一致）。
class ComposePage extends StatefulWidget {
  const ComposePage({super.key});

  @override
  State<ComposePage> createState() => _ComposePageState();
}

class _ComposePageState extends State<ComposePage> {
  static const int maxLen = 2000;

  final _ctrl = TextEditingController();
  int _visible = 0; // 0=公开 1=仅关注 6=仅自己
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内容不能为空')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final id = await api.postStatus(content: text, visible: _visible);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('已发布（id $id）')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发布失败：${describeError(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发微博'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _busy ? null : _publish,
              child: Text(_busy ? '发布中…' : '发布'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                expands: true,
                maxLength: maxLen,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: '有什么新鲜事想分享给大家？',
                  border: InputBorder.none,
                  counterText: '',
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('公开')),
                    ButtonSegment(value: 1, label: Text('仅关注')),
                    ButtonSegment(value: 6, label: Text('仅自己')),
                  ],
                  selected: {_visible},
                  onSelectionChanged: (s) => setState(() => _visible = s.first),
                  showSelectedIcon: false,
                ),
                const Spacer(),
                Text(
                  '${_ctrl.text.length}/$maxLen',
                  style: TextStyle(
                    fontSize: 12,
                    color: _ctrl.text.length > maxLen ? Colors.red : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
