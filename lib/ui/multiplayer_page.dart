import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import '../core/multiplayer.dart';
import '../core/multiplayer_invitation.dart';
import '../l10n/app_localizations.dart';
import 'byte_size.dart';
import 'collapsible_section.dart';
import 'scrolling.dart';
import 'theme.dart';

class MultiplayerPage extends StatefulWidget {
  final MultiplayerController controller;
  final VoidCallback? onOpenGame;
  const MultiplayerPage({required this.controller, this.onOpenGame, super.key});
  @override
  State<MultiplayerPage> createState() => _MultiplayerPageState();
}

class _MultiplayerPageState extends State<MultiplayerPage> {
  final input = TextEditingController(), port = TextEditingController();
  bool joining = false, working = false, answerPending = false;
  String? error, copiedTicket, copiedAddress;
  int operation = 0;
  MultiplayerController get network => widget.controller;
  bool get hosting => network.active || network.state == MultiplayerState.failed
      ? network.isHost
      : !joining;

  @override
  void initState() {
    super.initState();
    input.addListener(refreshInput);
    port.addListener(refreshInput);
  }

  void refreshInput() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    input.dispose();
    port.dispose();
    super.dispose();
  }

  Future<void> run(
    Future<void> Function() action, {
    bool interrupt = false,
  }) async {
    if (working && !interrupt) return;
    final current = ++operation;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted && current == operation) setState(() => error = '$e');
    } finally {
      if (mounted && current == operation) setState(() => working = false);
    }
  }

  void chooseRole(bool join) => setState(() {
    joining = join;
    input.clear();
    error = null;
  });

  String validate(String text, String kind) {
    try {
      return MultiplayerInvitation.parse(text, kind: kind).text;
    } on FormatException catch (original) {
      try {
        MultiplayerInvitation.parse(
          text,
          kind: kind == 'offer' ? 'answer' : 'offer',
        );
      } on FormatException {
        throw original;
      }
      throw FormatException(
        kind == 'offer' ? '这是回应信息，请让朋友发送邀请' : '这是邀请信息，请让朋友发送回应',
      );
    }
  }

  Future<String?> readInput(String kind) async {
    final current = operation;
    var text = input.text.trim();
    if (text.isEmpty) {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || current != operation) return null;
      text = clipboard?.text?.trim() ?? '';
      if (text.isEmpty) throw const FormatException('剪贴板里没有联机信息，请先复制朋友发来的内容');
    }
    final value = validate(text, kind);
    input.text = value;
    return value;
  }

  Future<void> start() => run(() async {
    answerPending = false;
    if (joining) {
      final value = await readInput('offer');
      if (value == null || !mounted) return;
      await network.join(value);
    } else {
      await network.host();
    }
    if (mounted && network.active) input.clear();
  });

  Future<void> connect() => run(() async {
    final value = await readInput('answer');
    if (value == null || !mounted) return;
    network.answer(value);
    setState(() => answerPending = true);
    input.clear();
  });

  Future<void> disconnect() => run(() async {
    final host = network.isHost;
    await network.stop();
    if (mounted) {
      setState(() {
        joining = !host;
        input.clear();
        answerPending = false;
      });
    }
  }, interrupt: true);

  Future<void> restart() => run(() async {
    final host = network.isHost;
    final invitation = network.lastInvitation;
    await network.stop();
    if (!mounted) return;
    setState(() {
      joining = !host;
      input.clear();
      answerPending = false;
    });
    if (host) await network.host();
    if (!host && invitation != null) {
      try {
        MultiplayerInvitation.parse(invitation, kind: 'offer');
      } on FormatException {
        return;
      }
      await network.join(invitation);
    }
  }, interrupt: true);

  Future<void> copy(String value, {bool address = false}) => run(() async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      setState(() {
        if (address) {
          copiedAddress = value;
        } else {
          copiedTicket = value;
        }
      });
    }
  });

  Widget note(String text) => LText(
    text,
    style: TextStyle(
      fontSize: 13,
      height: 1.6,
      color: LauncherColors.of(context).secondaryText,
    ),
  );
  Widget heading(String text) => LText(
    text,
    style: const TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.45,
    ),
  );

  Widget message(String text) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      key: const ValueKey('multiplayer-guidance-error'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: .22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(FIcons.circleAlert, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: LSelectableText(
              text,
              style: TextStyle(fontSize: 13, color: color),
            ),
          ),
        ],
      ),
    );
  }

  int get step {
    if (network.connected ||
        network.state == MultiplayerState.securing ||
        network.state == MultiplayerState.configuring) {
      return 2;
    }
    if (network.ticket != null) return 1;
    return 0;
  }

  Widget steps() => _FlowSteps(
    current: step,
    labels: hosting
        ? const ['创建房间', '交换联机信息', '开放游戏世界']
        : const ['粘贴邀请', '发送回应', '加入游戏'],
  );

  Widget entry() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final host = _RoleCard(
            title: '我是房主',
            description: '把我的游戏世界分享给朋友',
            icon: FIcons.gamepad2,
            selected: !joining,
            onPressed: working ? null : () => chooseRole(false),
            key: const ValueKey('multiplayer-role-host'),
          );
          final guest = _RoleCard(
            title: '加入朋友',
            description: '我已经收到了朋友的邀请',
            icon: FIcons.users,
            selected: joining,
            onPressed: working ? null : () => chooseRole(true),
            key: const ValueKey('multiplayer-role-guest'),
          );
          if (constraints.maxWidth < 480) {
            return Column(children: [host, const SizedBox(height: 10), guest]);
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: host),
              const SizedBox(width: 12),
              Expanded(child: guest),
            ],
          );
        },
      ),
      const SizedBox(height: 20),
      steps(),
      const SizedBox(height: 16),
      Surface(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            heading(joining ? '先粘贴朋友发来的邀请' : '准备好和朋友一起玩了吗？'),
            const SizedBox(height: 7),
            note(joining ? '生成回应后发回给朋友，由朋友完成连接' : '创建邀请发给朋友，收到朋友的回应后就能建立连接'),
            const SizedBox(height: 18),
            if (joining) ...[
              AppInput(
                key: const ValueKey('multiplayer-offer'),
                controller: input,
                label: '朋友的邀请信息',
                hint: '在这里粘贴完整的邀请信息',
                maxLines: 4,
                enabled: !working,
              ),
              const SizedBox(height: 14),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppButton(
                  joining
                      ? (input.text.trim().isEmpty ? '粘贴邀请并继续' : '生成回应信息')
                      : '创建邀请',
                  key: const ValueKey('multiplayer-start'),
                  icon: joining ? FIcons.clipboardPaste : FIcons.plus,
                  onPressed: working || !network.supported ? null : start,
                ),
                if (joining && input.text.isNotEmpty)
                  TextButton(
                    onPressed: working ? null : input.clear,
                    child: const LText('清空'),
                  ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(FIcons.users, size: 15, color: LauncherColors.of(context).muted),
          const SizedBox(width: 8),
          Expanded(
            child: LText(
              '双方都需要使用 FYL，并准备相同的游戏版本和 Mod',
              style: TextStyle(
                fontSize: 12,
                color: LauncherColors.of(context).muted,
              ),
            ),
          ),
        ],
      ),
    ],
  );

  Widget outgoingTicket() {
    final c = LauncherColors.of(context);
    final copied = copiedTicket == network.ticket;
    return Surface(
      padding: const EdgeInsets.all(20),
      color: c.accentBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                copied ? FIcons.check : FIcons.send,
                size: 20,
                color: c.accent,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: heading(
                  network.multiRoom
                      ? '把同一份邀请发给所有朋友'
                      : network.isHost
                      ? '先把邀请发给朋友'
                      : '把回应发给房主',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          note(
            network.multiRoom
                ? '朋友分别生成回应发给你，逐个导入即可连接；也可以稍后再邀请新人'
                : network.isHost
                ? '朋友在 FYL 中选择“加入朋友”，粘贴后会生成回应'
                : '房主导入你的回应后会自动连接，你可以留在这里等待',
          ),
          const SizedBox(height: 18),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              network.isHost
                  ? (copied
                        ? '已复制邀请'
                        : network.multiRoom
                        ? '复制房间邀请'
                        : '复制邀请')
                  : (copied ? '已复制回应' : '复制回应'),
              key: const ValueKey('multiplayer-copy-ticket'),
              icon: copied ? FIcons.check : FIcons.copy,
              secondary: copied,
              onPressed: working || (network.multiRoom && !network.accepting)
                  ? null
                  : () => copy(network.ticket!),
            ),
          ),
          if (network.multiRoom) ...[
            const SizedBox(height: 12),
            if (!network.accepting) ...[
              LText(
                network.invitationExpired
                    ? '邀请已过期，在线朋友不受影响'
                    : '已停止接纳新人，在线朋友不受影响',
              ),
              const SizedBox(height: 10),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AppButton(
                  '重新生成邀请',
                  small: true,
                  secondary: true,
                  icon: FIcons.refreshCw,
                  onPressed: working
                      ? null
                      : () => run(() async {
                          network.refreshInvitation();
                          copiedTicket = null;
                          input.clear();
                        }),
                ),
                if (network.accepting)
                  AppButton(
                    '停止接纳新人',
                    small: true,
                    secondary: true,
                    onPressed: working
                        ? null
                        : () => run(() async => network.pauseInvitation()),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            note('重新生成会使旧邀请失效，在线朋友不受影响'),
          ],
          if (network.expires != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '${tr('有效期至')} ${TimeOfDay.fromDateTime(network.expires!).format(context)}',
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 14),
          CollapsibleSection(
            title: '查看完整内容',
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: AppScrollView(
                child: SelectableText(
                  network.ticket!,
                  style: TextStyle(
                    color: c.secondaryText,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget exchange() {
    final send = outgoingTicket();
    if (!network.isHost) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          send,
          const SizedBox(height: 12),
          _WaitingLine(
            text: copiedTicket == network.ticket
                ? '等待房主导入回应，连接成功后会自动进入下一步'
                : '复制上方回应，发送给刚才邀请你的朋友',
          ),
        ],
      );
    }
    final receive = Surface(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading('收到朋友的回应了吗？'),
          const SizedBox(height: 8),
          note(
            network.multiRoom
                ? '每位朋友的回应各不相同，逐个粘贴即可添加到房间'
                : '把朋友生成的回应粘贴到这里，即可开始连接',
          ),
          const SizedBox(height: 16),
          AppInput(
            key: const ValueKey('multiplayer-answer'),
            controller: input,
            label: '朋友的回应信息',
            hint: '这里需要回应信息，不是你刚才的邀请',
            maxLines: 4,
            enabled: !working,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              input.text.trim().isEmpty ? '粘贴回应并连接' : '连接朋友',
              key: const ValueKey('multiplayer-connect'),
              icon: input.text.trim().isEmpty
                  ? FIcons.clipboardPaste
                  : FIcons.arrowRight,
              onPressed: working || (network.multiRoom && !network.accepting)
                  ? null
                  : connect,
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        if (constraints.maxWidth < 760 * scale.clamp(1.0, 1.4)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [send, const SizedBox(height: 14), receive],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 4, child: send),
            const SizedBox(width: 14),
            Expanded(flex: 5, child: receive),
          ],
        );
      },
    );
  }

  Widget progress() {
    final stopping = network.state == MultiplayerState.stopping;
    final preparing = network.ticket == null && !answerPending;
    return Surface(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WaitingLine(
            text: stopping
                ? '正在结束这次联机'
                : preparing
                ? (network.isHost ? '正在准备邀请' : '正在生成回应')
                : '正在建立你们的连接',
            large: true,
          ),
          const SizedBox(height: 10),
          note(
            stopping
                ? '稍等片刻，连接关闭后即可重新开始'
                : preparing
                ? '准备完成后，这里会显示下一步操作'
                : '连接成功后，我们会告诉你如何进入游戏',
          ),
          const SizedBox(height: 18),
          if (!MediaQuery.disableAnimationsOf(context))
            LinearProgressIndicator(
              minHeight: 3,
              color: LauncherColors.of(context).accent,
              backgroundColor: LauncherColors.of(context).raised,
            ),
          const SizedBox(height: 10),
          LText(
            network.state.label,
            style: TextStyle(
              fontSize: 12,
              color: LauncherColors.of(context).muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget roomView() {
    final c = LauncherColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            const Tag('房主', accent: true),
            Tag('已连接 ${network.connectedPeers} 位朋友'),
            Tag(network.accepting ? '邀请可用' : '邀请已停用'),
          ],
        ),
        const SizedBox(height: 16),
        exchange(),
        const SizedBox(height: 16),
        CollapsibleSection(
          key: ValueKey('room-world-${network.connectedPeers > 0}'),
          title: '共享的游戏世界',
          icon: FIcons.gamepad2,
          initiallyExpanded: network.connectedPeers > 0 || network.gamePort > 0,
          child: connected(embedded: true),
        ),
        const SizedBox(height: 20),
        heading('朋友的连接'),
        const SizedBox(height: 10),
        if (network.peers.isEmpty)
          Surface(
            padding: const EdgeInsets.all(18),
            child: note('还没有朋友连接，先把房间邀请发给他们吧'),
          ),
        for (final peer in network.peers.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Surface(
              key: ValueKey('multiplayer-peer-${peer.id}'),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        peer.connected ? FIcons.userCheck : FIcons.user,
                        size: 22,
                        color: peer.connected ? c.accent : c.muted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            LText(
                              '朋友 ${peer.number}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            LText(
                              peer.state.label,
                              style: TextStyle(
                                fontSize: 12,
                                color: c.secondaryText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      AppButton(
                        peer.state == MultiplayerState.failed ? '移除' : '断开',
                        key: ValueKey('remove-peer-${peer.id}'),
                        small: true,
                        secondary: true,
                        onPressed: working
                            ? null
                            : () =>
                                  run(() async => network.removePeer(peer.id)),
                      ),
                    ],
                  ),
                  if (peer.error != null) ...[
                    const SizedBox(height: 10),
                    LText(
                      peer.error!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 6),
                    note('请这位朋友使用房间邀请重新生成回应，再粘贴到上方'),
                  ],
                  if (peer.sent > 0 || peer.received > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${tr('已发送')} ${formatByteSize(peer.sent)} · ${tr('已接收')} ${formatByteSize(peer.received)}',
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget instruction(int number, String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 23,
          height: 23,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: LauncherColors.of(context).raised,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Text(
            '$number',
            style: TextStyle(
              color: LauncherColors.of(context).secondaryText,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: note(text)),
      ],
    ),
  );

  Widget connected({bool embedded = false}) {
    final c = LauncherColors.of(context);
    final ready = network.gamePort > 0;
    final reconnecting = network.state == MultiplayerState.reconnecting;
    final title = reconnecting
        ? '正在恢复连接'
        : network.isHost
        ? (ready ? '世界已开放，朋友可以加入了' : '接下来，开放你的游戏世界')
        : (ready ? '世界已准备好，可以加入了' : '已连接，等待房主开放世界');
    Widget frame(Widget child) => embedded
        ? child
        : Surface(padding: const EdgeInsets.all(24), child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        frame(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: c.accentBackground,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      reconnecting ? FIcons.refreshCw : FIcons.check,
                      color: c.accent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        heading(title),
                        const SizedBox(height: 5),
                        note(
                          reconnecting
                              ? '正在尝试恢复连接，请暂时留在游戏中'
                              : network.isHost
                              ? '联机通道已就绪，接下来在 Minecraft 中操作'
                              : '保持 FYL 开启，联机连接会在后台运行',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (network.isHost && !ready) ...[
                instruction(1, '进入想和朋友一起玩的单人世界'),
                instruction(2, '按 Esc，选择“对局域网开放”'),
                instruction(3, '点击“开始局域网世界”，FYL 会自动找到它'),
                if (widget.onOpenGame != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AppButton(
                        '前往开始游戏',
                        icon: FIcons.gamepad2,
                        onPressed: widget.onOpenGame,
                      ),
                    ),
                  ),
              ] else if (ready) ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: c.raised,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(FIcons.gamepad2, color: c.accent, size: 22),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          network.gameName?.isNotEmpty == true
                              ? network.gameName!
                              : tr('Minecraft 局域网世界'),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                note(
                  network.isHost
                      ? '让朋友打开多人游戏，选择带有 FYL 标记的局域网世界'
                      : '打开 Minecraft 的多人游戏，选择带有 FYL 标记的局域网世界',
                ),
                if (!network.isHost && network.gameAddress != null) ...[
                  const SizedBox(height: 18),
                  CollapsibleSection(
                    title: '没有看到局域网世界？',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        note('在多人游戏中选择“直接连接”，粘贴下方地址即可加入'),
                        const SizedBox(height: 12),
                        SelectableText(
                          network.gameAddress!,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: c.foreground,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppButton(
                            copiedAddress == network.gameAddress
                                ? '已复制地址'
                                : '复制直连地址',
                            key: const ValueKey('multiplayer-copy-address'),
                            icon: copiedAddress == network.gameAddress
                                ? FIcons.check
                                : FIcons.copy,
                            small: true,
                            onPressed: working
                                ? null
                                : () =>
                                      copy(network.gameAddress!, address: true),
                          ),
                        ),
                        const SizedBox(height: 10),
                        LText(
                          '此地址只用于你这台电脑，不需要发给朋友',
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ] else ...[
                const SizedBox(height: 18),
                const _WaitingLine(text: '房主开放世界后，这里会自动显示'),
              ],
            ],
          ),
        ),
        if (network.isHost) ...[const SizedBox(height: 14), manualPort()],
      ],
    );
  }

  Widget manualPort() => CollapsibleSection(
    title: network.gamePort > 0 ? '更换游戏端口' : '没有自动找到游戏？',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        note('在游戏聊天栏找到局域网端口，填入后即可手动共享这个世界'),
        const SizedBox(height: 12),
        AppInput(
          key: const ValueKey('multiplayer-port'),
          controller: port,
          label: '游戏端口',
          hint: '例如 25565',
          compact: true,
          inlineLabel: true,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              '使用此端口',
              small: true,
              onPressed: working || port.text.trim().isEmpty
                  ? null
                  : () => run(() async {
                      final value = int.tryParse(port.text.trim());
                      if (value == null || value < 1 || value > 65535) {
                        throw const FormatException('游戏端口无效');
                      }
                      network.sharePort(value);
                    }),
            ),
            AppButton(
              '恢复自动识别',
              small: true,
              secondary: true,
              onPressed: working
                  ? null
                  : () => run(() async {
                      network.sharePort(0);
                      port.clear();
                    }),
            ),
          ],
        ),
      ],
    ),
  );

  Widget failure() => Surface(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading('连接没有成功'),
        const SizedBox(height: 12),
        message(error ?? network.error ?? '联机失败，请检查网络后重试'),
        const SizedBox(height: 14),
        note('确认双方网络可用；联机信息过期时，需要重新创建邀请'),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: AppButton(
            network.isHost
                ? '重新创建房间'
                : network.lastInvitation != null
                ? '重新生成回应'
                : '重新粘贴邀请',
            key: const ValueKey('multiplayer-restart'),
            icon: FIcons.refreshCw,
            onPressed: working ? null : restart,
          ),
        ),
      ],
    ),
  );

  Widget details() {
    final c = LauncherColors.of(context);
    return CollapsibleSection(
      title: '连接详情',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText(
            network.state.label,
            style: TextStyle(color: c.secondaryText, fontSize: 13),
          ),
          if (network.room != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText(
                network.room!,
                style: TextStyle(color: c.muted, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '${tr('已发送')} ${formatByteSize(network.sent)} · ${tr('已接收')} ${formatByteSize(network.received)}',
            style: TextStyle(color: c.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: network,
    builder: (context, _) {
      final c = LauncherColors.of(context);
      final failed = network.state == MultiplayerState.failed;
      final hasSession = network.active || failed;
      final exchanging =
          network.ticket != null &&
          !network.connected &&
          !failed &&
          (network.isHost
              ? network.state == MultiplayerState.waitingAnswer &&
                    (!answerPending || network.error != null)
              : network.state == MultiplayerState.connecting);
      return AppScrollView(
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Expanded(
                      child: LText(
                        '联机',
                        style: TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.6,
                        ),
                      ),
                    ),
                    if (network.active)
                      AppButton(
                        network.state == MultiplayerState.stopping
                            ? '正在断开联机'
                            : network.hostingRoom
                            ? '结束房间'
                            : '断开联机',
                        key: const ValueKey('multiplayer-disconnect'),
                        secondary: true,
                        small: true,
                        onPressed: network.state == MultiplayerState.stopping
                            ? null
                            : disconnect,
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                note('和朋友一起玩，从分享一个游戏世界开始'),
                const SizedBox(height: 24),
                if (hasSession && !network.hostingRoom) ...[
                  Row(
                    children: [
                      Tag(network.isHost ? '房主' : '加入者', accent: true),
                      const SizedBox(width: 10),
                      Expanded(
                        child: LText(
                          network.state == MultiplayerState.reconnecting
                              ? '正在恢复连接'
                              : network.connected
                              ? '你们已经连接'
                              : '跟着下面的步骤完成联机',
                          style: TextStyle(color: c.muted, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  steps(),
                  const SizedBox(height: 18),
                ],
                if (!failed && (error != null || network.error != null)) ...[
                  message(error ?? network.error!),
                  const SizedBox(height: 14),
                ],
                if (failed)
                  failure()
                else if (network.hostingRoom)
                  roomView()
                else if (network.connected)
                  connected()
                else if (exchanging)
                  exchange()
                else if (network.active)
                  progress()
                else
                  entry(),
                const SizedBox(height: 20),
                if (network.connected ||
                    network.active && network.ticket != null) ...[
                  details(),
                  const SizedBox(height: 12),
                ],
                CollapsibleSection(
                  title: '联机前需要知道什么？',
                  icon: FIcons.info,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      note('双方都需要使用 FYL，并准备相同的游戏版本和 Mod'),
                      const SizedBox(height: 8),
                      note('保持启动器开启，关闭 FYL 会结束这次联机'),
                      const SizedBox(height: 8),
                      note('仅共享 Minecraft 游戏连接，不影响其他应用的网络'),
                      const SizedBox(height: 8),
                      note('部分网络可能无法直连，连接失败时可以重新创建房间再试'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _RoleCard extends StatelessWidget {
  final String title, description;
  final IconData icon;
  final bool selected;
  final VoidCallback? onPressed;
  const _RoleCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.selected,
    this.onPressed,
    super.key,
  });
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? c.accentBackground : c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? c.accent.withValues(alpha: .65) : c.border,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected ? c.accent : c.secondaryText,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: selected ? c.accent : c.foreground,
                        ),
                      ),
                      const SizedBox(height: 5),
                      LText(
                        description,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: c.secondaryText,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected ? FIcons.circleCheck : FIcons.circle,
                  size: 17,
                  color: selected ? c.accent : c.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowSteps extends StatelessWidget {
  final List<String> labels;
  final int current;
  const _FlowSteps({required this.labels, required this.current});
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i != 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 13, 8, 0),
              child: Icon(FIcons.chevronRight, size: 13, color: c.muted),
            ),
          Expanded(
            child: Semantics(
              label: tr(labels[i]),
              selected: i == current,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 27,
                    height: 27,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i <= current ? c.accentBackground : c.raised,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: i < current
                        ? Icon(FIcons.check, size: 15, color: c.accent)
                        : Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: i == current ? c.accent : c.muted,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: LText(
                        labels[i],
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: i == current ? c.foreground : c.muted,
                          fontWeight: i == current
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _WaitingLine extends StatelessWidget {
  final String text;
  final bool large;
  const _WaitingLine({required this.text, this.large = false});
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: large ? 22 : 16,
          height: large ? 22 : 16,
          child: MediaQuery.disableAnimationsOf(context)
              ? Icon(
                  FIcons.loaderCircle,
                  size: large ? 22 : 16,
                  color: c.accent,
                )
              : CircularProgressIndicator(strokeWidth: 2, color: c.accent),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: LText(
            text,
            style: TextStyle(
              fontSize: large ? 17 : 13,
              fontWeight: large ? FontWeight.w600 : FontWeight.w400,
              color: large ? c.foreground : c.secondaryText,
            ),
          ),
        ),
      ],
    );
  }
}
