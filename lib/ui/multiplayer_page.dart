import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../core/multiplayer.dart';
import '../l10n/app_localizations.dart';
import 'byte_size.dart';
import 'collapsible_section.dart';
import 'pages.dart' show PageHeader;
import 'scrolling.dart';
import 'theme.dart';

class MultiplayerPage extends StatefulWidget {
  final MultiplayerController controller;
  const MultiplayerPage({required this.controller, super.key});
  @override
  State<MultiplayerPage> createState() => _MultiplayerPageState();
}

class _MultiplayerPageState extends State<MultiplayerPage> {
  final input = TextEditingController(), port = TextEditingController();
  bool joining = false, working = false;
  String? error;
  @override
  void dispose() {
    input.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() operation) async {
    if (working) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> copy(String value) =>
      Clipboard.setData(ClipboardData(text: value));

  Widget address(String label, String? value) => Row(
    children: [
      LText(label, style: const TextStyle(fontSize: 13)),
      const SizedBox(width: 12),
      Expanded(
        child: SelectableText(
          value ?? '—',
          style: const TextStyle(fontSize: 14),
        ),
      ),
      if (value != null)
        IconButton(
          tooltip: tr('复制'),
          icon: const Icon(FIcons.copy, size: 16),
          onPressed: () => copy(value),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final network = widget.controller;
      final c = LauncherColors.of(context);
      final idle = !network.active;
      return AppScrollView(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const PageHeader(title: '联机', subtitle: '通过邀请和回应与朋友直连 Minecraft'),
            Surface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        network.connected ? FIcons.network : FIcons.radio,
                        color: c.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: LText(
                          network.state.label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (network.active ||
                          network.state == MultiplayerState.failed)
                        AppButton(
                          '断开联机',
                          secondary: true,
                          small: true,
                          onPressed: network.state == MultiplayerState.stopping
                              ? null
                              : () => run(network.stop),
                        ),
                    ],
                  ),
                  if (network.room != null) ...[
                    const SizedBox(height: 10),
                    address('当前房间', network.room),
                  ],
                  if (network.connected) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${tr('已发送')} ${formatByteSize(network.sent)} · ${tr('已接收')} ${formatByteSize(network.received)}',
                      style: TextStyle(fontSize: 12, color: c.muted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (idle)
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AppButton(
                          '创建房间',
                          small: true,
                          secondary: joining,
                          onPressed: working
                              ? null
                              : () => setState(() {
                                  joining = false;
                                  input.clear();
                                  error = null;
                                }),
                        ),
                        AppButton(
                          '加入房间',
                          small: true,
                          secondary: !joining,
                          onPressed: working
                              ? null
                              : () => setState(() {
                                  joining = true;
                                  input.clear();
                                  error = null;
                                }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (joining) ...[
                      AppInput(
                        key: const ValueKey('multiplayer-offer'),
                        controller: input,
                        label: '邀请信息',
                        hint: '粘贴房主发送的 FYL1: 邀请信息',
                        maxLines: 5,
                        enabled: !working,
                      ),
                      const SizedBox(height: 10),
                    ],
                    Align(
                      alignment: Alignment.centerLeft,
                      child: AppButton(
                        joining ? '生成回应信息' : '生成邀请信息',
                        icon: FIcons.network,
                        onPressed: working || !network.supported
                            ? null
                            : () => run(() async {
                                if (joining) {
                                  await network.join(input.text);
                                } else {
                                  await network.host();
                                }
                                if (mounted && network.active) {
                                  setState(input.clear);
                                }
                              }),
                      ),
                    ),
                    const SizedBox(height: 10),
                    LText(
                      '仅共享 Minecraft 游戏端口，不修改系统网卡、路由或代理',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            if (network.ticket != null && !network.connected)
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: LText(
                            network.isHost ? '邀请信息' : '回应信息',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        AppButton(
                          '复制',
                          icon: FIcons.copy,
                          small: true,
                          onPressed: () => copy(network.ticket!),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LText(
                      network.isHost
                          ? '将邀请信息发给朋友，再导入朋友生成的回应信息'
                          : '将回应信息发给房主，等待房主导入',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    CollapsibleSection(
                      title: '查看联机信息',
                      child: SelectableText(
                        network.ticket!,
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ),
                    if (network.expires != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${tr('有效期至')} ${TimeOfDay.fromDateTime(network.expires!).format(context)}',
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                      ),
                    if (network.isHost &&
                        network.state == MultiplayerState.waitingAnswer) ...[
                      const SizedBox(height: 12),
                      AppInput(
                        key: const ValueKey('multiplayer-answer'),
                        controller: input,
                        label: '回应信息',
                        hint: '粘贴朋友生成的 FYL1: 回应信息',
                        maxLines: 5,
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: AppButton(
                          '导入回应并连接',
                          small: true,
                          onPressed: () => run(() async {
                            network.answer(input.text);
                            input.clear();
                          }),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (network.connected) ...[
              const SizedBox(height: 14),
              Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LText(
                      'Minecraft 局域网世界',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    LText(
                      network.isHost
                          ? '进入游戏世界并对局域网开放，FYL 会自动识别游戏端口'
                          : '打开多人游戏查看局域网世界，或复制游戏地址直接连接',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                    if (network.gamePort > 0) ...[
                      const SizedBox(height: 8),
                      if (network.gameName?.isNotEmpty ?? false)
                        Text(
                          network.gameName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      address('游戏地址', network.gameAddress),
                    ],
                    if (network.isHost) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SizedBox(
                            width: 220,
                            child: AppInput(
                              key: const ValueKey('multiplayer-port'),
                              controller: port,
                              label: '手动指定游戏端口',
                              compact: true,
                              inlineLabel: true,
                            ),
                          ),
                          AppButton(
                            '应用',
                            small: true,
                            secondary: true,
                            onPressed: () => run(() async {
                              final value = int.tryParse(port.text.trim());
                              if (value == null || value < 1 || value > 65535) {
                                throw const FormatException('游戏端口无效');
                              }
                              network.sharePort(value);
                            }),
                          ),
                          AppButton(
                            '自动识别',
                            small: true,
                            secondary: true,
                            onPressed: () => network.sharePort(0),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (network.error != null || error != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: LSelectableText(
                  error ?? network.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            LText(
              '使用公共 STUN 尝试直连，不经过游戏中继；部分网络可能无法连接',
              style: TextStyle(color: c.muted, fontSize: 12),
            ),
          ],
        ),
      );
    },
  );
}
