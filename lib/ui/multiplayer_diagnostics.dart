import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/multiplayer.dart';
import '../l10n/app_localizations.dart';
import 'byte_size.dart';
import 'collapsible_section.dart';
import 'scrolling.dart';
import 'theme.dart';

class MultiplayerDiagnosticsPanel extends StatelessWidget {
  final MultiplayerController network;
  final VoidCallback onCopy;
  final bool copied;
  const MultiplayerDiagnosticsPanel({
    required this.network,
    required this.onCopy,
    this.copied = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SettingsRow(
        label: label,
        child: SelectableText(
          value,
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
      ),
    );
    String display(Object? value) => value == null ? tr('尚无数据') : '$value';
    Widget connection(Map<String, dynamic> data, {String? code}) {
      final rtt = data['iceRTTms'];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line('选中的本地候选', display(data['selectedLocal'])),
          line('选中的远端候选', display(data['selectedRemote'])),
          line(
            'ICE 探测往返延迟',
            rtt is num && rtt > 0 && rtt.isFinite
                ? '${rtt.toStringAsFixed(1)} ms'
                : tr('尚无数据'),
          ),
          line(
            '对端身份校验',
            tr(data['identityVerified'] == true ? '已验证证书指纹' : '尚未完成验证'),
          ),
          line('本机证书 SHA-256', display(data['localFingerprint'])),
          line('对端证书 SHA-256', display(data['remoteFingerprint'])),
          if (code != null) line('原始错误码', code),
          if (data['localCandidates'] case final List candidates) ...[
            const SizedBox(height: 6),
            CollapsibleSection(
              title: '全部本地候选地址',
              child: SelectableText(
                candidates.join('\n'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            ),
          ],
        ],
      );
    }

    final mappings = network.diagnostics['stunMappings'] as List? ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppButton(
              copied ? '诊断已复制' : '复制诊断',
              key: const ValueKey('copy-multiplayer-diagnostics'),
              icon: FIcons.copy,
              onPressed: onCopy,
            ),
            AppButton(
              '清除诊断',
              secondary: true,
              onPressed: network.active ? null : network.clearDiagnostics,
            ),
          ],
        ),
        const SizedBox(height: 10),
        LText(
          '诊断包含 IP 地址和证书指纹，不含邀请密钥、ICE 密码或账户信息',
          style: TextStyle(fontSize: 12, color: c.secondaryText),
        ),
        const SizedBox(height: 16),
        Surface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LText(
                network.active ? '当前联机诊断' : '上次联机诊断',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              line('连接状态', tr(network.state.label)),
              line('传输协议', 'ICE / UDP → DTLS 1.2 → SCTP → Minecraft TCP'),
              line('中继与 TCP 隧道', tr('当前未实现，仅支持 UDP 直连')),
              line('NAT 类型', tr('未检测，不能仅凭候选地址判断')),
              line('房间标识', display(network.room)),
              line('网络助手位置', network.helperPath()),
              line(
                '累计传输',
                '${tr('已发送')} ${formatByteSize(network.diagnosticSent)} · ${tr('已接收')} ${formatByteSize(network.diagnosticReceived)}',
              ),
              connection(network.diagnostics, code: network.errorCode),
            ],
          ),
        ),
        const SizedBox(height: 16),
        CollapsibleSection(
          title: 'STUN 探测结果',
          initiallyExpanded: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (mappings.isEmpty) LText('尚无探测结果'),
              for (final raw in mappings) ...[
                line('本地 UDP 地址', display(raw['local'])),
                line('STUN 服务器地址', display(raw['server'])),
                line(
                  '探测状态',
                  tr(switch (raw['status']) {
                    'success' => '探测成功',
                    'disabled' => '已停用 STUN',
                    _ => '未获得映射地址',
                  }),
                ),
                line('映射后的公网地址', display(raw['mapped'])),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (final peer in network.peers.values) ...[
          CollapsibleSection(
            title: '朋友 ${peer.number}',
            initiallyExpanded: true,
            child: connection(peer.diagnostics, code: peer.errorCode),
          ),
          const SizedBox(height: 12),
        ],
        if (network.peers.isEmpty)
          for (final peer in network.lastPeerDiagnostics) ...[
            CollapsibleSection(
              title: '朋友 ${peer['number']}',
              child: connection(peer, code: peer['errorCode'] as String?),
            ),
            const SizedBox(height: 12),
          ],
        CollapsibleSection(
          title: '本次联机使用的设置',
          child: SelectableText(
            const JsonEncoder.withIndent('  ').convert(
              network.sessionSettings?.toJson() ?? network.settings.toJson(),
            ),
            style: const TextStyle(fontSize: 12, height: 1.6),
          ),
        ),
        const SizedBox(height: 12),
        CollapsibleSection(
          title: '连接事件与错误码',
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: AppScrollView(
              child: SelectableText(
                network.diagnosticEvents.isEmpty
                    ? tr('尚无连接事件')
                    : network.diagnosticEvents
                          .map(
                            (e) =>
                                '${e['time']}  ${e['peer'] == null ? '' : '#${e['peer']}  '}${e['type']} ${e['value'] ?? ''}',
                          )
                          .join('\n'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
