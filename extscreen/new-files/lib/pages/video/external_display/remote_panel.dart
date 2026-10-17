import 'dart:async';

import 'package:PiliPlus/pages/video/external_display/service.dart';
import 'package:flutter/material.dart';

/// 主屏遥控面板：外接屏播放时替换本机视频画面，
/// 提供播放/暂停、进度、倍速控制，并实时显示副屏播放状态。
class ExternalRemotePanel extends StatefulWidget {
  const ExternalRemotePanel({
    super.key,
    required this.onBackToLocal,
    required this.title,
  });

  final VoidCallback onBackToLocal;
  final String title;

  @override
  State<ExternalRemotePanel> createState() => _ExternalRemotePanelState();
}

class _ExternalRemotePanelState extends State<ExternalRemotePanel> {
  StreamSubscription<Map<String, dynamic>>? _sub;

  int _position = 0;
  int _duration = 0;
  bool _playing = false;
  bool _seeking = false;
  String? _error;

  static const List<double> _rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
  int _rateIndex = 2;

  @override
  void initState() {
    super.initState();
    _sub = ExternalDisplayService.events.listen(_onEvent);
    ExternalDisplayService.sendToExternal('getPos', null);
  }

  void _onEvent(Map<String, dynamic> event) {
    switch (event['event']) {
      case 'state':
        final data = Map<String, dynamic>.from(event['data'] as Map? ?? {});
        if (!mounted) return;
        setState(() {
          _position = (data['position'] as num?)?.toInt() ?? _position;
          _duration = (data['duration'] as num?)?.toInt() ?? _duration;
          _playing = (data['playing'] as bool?) ?? _playing;
        });
        break;
      case 'playbackError':
        final data = Map<String, dynamic>.from(event['data'] as Map? ?? {});
        if (!mounted) return;
        setState(() {
          _error = data['error']?.toString();
        });
        break;
      case 'dismissed':
        // 外接屏断开（拔线/投屏断开），自动回到本机播放
        if (mounted) widget.onBackToLocal();
        break;
    }
  }

  String _fmt(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      // 显式 opaque：拦截所有触摸，防止穿透到下层的可聚焦组件（如弹幕输入）
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      // 面板整体高度可能超出播放器条高度：用 FittedBox 等比缩放，
      // 保证底部「倍速 / 回到本机播放」等控件始终落在父级可命中区域内
      // （否则溢出部分看得见却点不到，且触摸会穿透到下层）
      child: LayoutBuilder(
        builder: (context, constraints) => FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: constraints.maxWidth,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.connected_tv, color: Colors.white38, size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white60, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _error ?? '正在外接显示器上播放，本机作为遥控器',
            style: TextStyle(
              color: _error != null ? Colors.redAccent : Colors.white24,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: () => ExternalDisplayService.sendToExternal('seek', {
                  'position': (_position - 10000).clamp(0, 1 << 31),
                }),
                icon: const Icon(Icons.replay_10, color: Colors.white70),
              ),
              const SizedBox(width: 8),
              Container(
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: () => ExternalDisplayService.sendToExternal(
                    _playing ? 'pause' : 'play',
                    null,
                  ),
                  iconSize: 40,
                  icon: Icon(
                    _playing ? Icons.pause : Icons.play_arrow,
                    size: 40,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                onPressed: () => ExternalDisplayService.sendToExternal('seek', {
                  'position': (_position + 30000).clamp(0, 1 << 31),
                }),
                icon: const Icon(Icons.forward_30, color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                _fmt(_position),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                  ),
                  child: Slider(
                    value: _duration > 0
                        ? _position.clamp(0, _duration).toDouble()
                        : 0,
                    max: _duration > 0 ? _duration.toDouble() : 1,
                    activeColor: colorScheme.primary,
                    inactiveColor: Colors.white24,
                    onChangeStart: (_) => _seeking = true,
                    onChangeEnd: (v) {
                      _seeking = false;
                      ExternalDisplayService.sendToExternal('seek', {
                        'position': v.toInt(),
                      });
                    },
                    onChanged: (v) {
                      if (_seeking) {
                        setState(() => _position = v.toInt());
                      }
                    },
                  ),
                ),
              ),
              Text(
                _fmt(_duration),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              FilledButton.tonal(
                onPressed: () {
                  _rateIndex = (_rateIndex + 1) % _rates.length;
                  final rate = _rates[_rateIndex];
                  ExternalDisplayService.sendToExternal('setRate', {'rate': rate});
                  setState(() {});
                },
                child: Text('${_rates[_rateIndex]}x'),
              ),
              FilledButton.icon(
                onPressed: widget.onBackToLocal,
                icon: const Icon(Icons.smartphone),
                label: const Text('回到本机播放'),
              ),
            ],
          ),
        ],
      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
