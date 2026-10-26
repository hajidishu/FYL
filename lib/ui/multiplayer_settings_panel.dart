import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../core/multiplayer.dart';
import '../core/multiplayer_settings.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

/// Owned by the multiplayer page, so switching its tabs retains unsaved edits.
class MultiplayerSettingsDraft extends ChangeNotifier {
  final MultiplayerController network;
  final fields = <String, TextEditingController>{};
  late String family, interfaceName;
  late bool discoverLAN, announceLAN;
  bool saving = false, dirty = false, saved = false, disposed = false;
  String? error;
  List<String> interfaces = [];
  MultiplayerSettingsDraft(this.network) {
    final data = network.settings.toJson();
    family = data['addressFamily'] as String;
    interfaceName = data['interfaceName'] as String;
    discoverLAN = data['discoverLAN'] as bool;
    announceLAN = data['announceLAN'] as bool;
    for (final name in [
      'localPort',
      'stunTimeout',
      'connectTimeout',
      'invitationMinutes',
      'maxPeers',
    ]) {
      fields[name] = TextEditingController(text: '${data[name]}')
        ..addListener(changed);
    }
    fields['stunServers'] = TextEditingController(
      text: network.settings.stunServers.join('\n'),
    )..addListener(changed);
    unawaited(refreshInterfaces());
  }
  void changed() {
    if (disposed) return;
    dirty = true;
    saved = false;
    error = null;
    notifyListeners();
  }

  Future<void> refreshInterfaces() async {
    try {
      final found = await NetworkInterface.list();
      if (disposed) return;
      interfaces = found.map((value) => value.name).toSet().toList()..sort();
      if (error == '无法读取网卡列表，请稍后刷新') error = null;
      notifyListeners();
    } catch (_) {
      if (!disposed) {
        error = '无法读取网卡列表，请稍后刷新';
        notifyListeners();
      }
    }
  }

  void reset(String key) {
    final defaults = const MultiplayerSettings().toJson();
    switch (key) {
      case 'addressFamily':
        family = defaults[key] as String;
      case 'interfaceName':
        interfaceName = '';
      case 'discoverLAN':
        discoverLAN = true;
      case 'announceLAN':
        announceLAN = true;
      case 'stunServers':
        fields[key]!.text = (defaults[key] as List).join('\n');
      default:
        fields[key]!.text = '${defaults[key]}';
    }
    changed();
  }

  Future<void> save() async {
    if (saving) return;
    saving = true;
    error = null;
    notifyListeners();
    try {
      int number(String key) {
        final value = int.tryParse(fields[key]!.text.trim());
        if (value == null) throw const FormatException('联机设置超出允许范围，请检查输入');
        return value;
      }

      await network.saveSettings(
        MultiplayerSettings(
          addressFamily: family,
          interfaceName: interfaceName,
          stunServers: fields['stunServers']!.text
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList(),
          localPort: number('localPort'),
          stunTimeout: number('stunTimeout'),
          connectTimeout: number('connectTimeout'),
          invitationMinutes: number('invitationMinutes'),
          maxPeers: number('maxPeers'),
          discoverLAN: discoverLAN,
          announceLAN: announceLAN,
        ),
      );
      if (disposed) return;
      dirty = false;
      saved = true;
    } catch (e) {
      if (!disposed) error = e is FormatException ? e.message : '保存联机设置失败：$e';
    } finally {
      if (!disposed) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }
}

class MultiplayerSettingsPanel extends StatelessWidget {
  final MultiplayerSettingsDraft draft;
  const MultiplayerSettingsPanel({required this.draft, super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) {
      final c = LauncherColors.of(context);
      Widget row(
        String key,
        String label,
        Widget child, {
        String? description,
      }) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SettingsRow(
          label: label,
          description: description,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: child),
              const SizedBox(width: 6),
              IconButton(
                key: ValueKey('reset-multiplayer-$key'),
                tooltip: tr('重置此项'),
                icon: const Icon(FIcons.rotateCcw, size: 15),
                onPressed: draft.saving ? null : () => draft.reset(key),
              ),
            ],
          ),
        ),
      );
      Widget number(String key) => AppInput(
        key: ValueKey('multiplayer-setting-$key'),
        controller: draft.fields[key],
        compact: true,
        enabled: !draft.saving,
      );
      Widget toggle(
        String key,
        String label,
        bool value,
        ValueChanged<bool> change,
      ) => row(
        key,
        label,
        Align(
          alignment: Alignment.centerLeft,
          child: FSwitch(
            value: value,
            semanticsLabel: tr(label),
            onChange: draft.saving
                ? null
                : (v) {
                    change(v);
                    draft.changed();
                  },
          ),
        ),
      );
      final interfaceItems = <String, String>{
        '': tr('自动选择网卡'),
        for (final name in draft.interfaces) name: name,
        if (draft.interfaceName.isNotEmpty &&
            !draft.interfaces.contains(draft.interfaceName))
          draft.interfaceName: '${draft.interfaceName} (${tr('当前不可用')})',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText(
            '修改将在下次创建房间或加入时生效，不会断开当前连接',
            style: TextStyle(fontSize: 13, color: c.secondaryText),
          ),
          const SizedBox(height: 16),
          Surface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const LText(
                  '网络连接',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                row(
                  'addressFamily',
                  'IP 协议',
                  SelectBox<String>(
                    key: const ValueKey('multiplayer-setting-addressFamily'),
                    value: draft.family,
                    items: const {
                      'both': 'IPv4 和 IPv6',
                      'ipv4': '仅 IPv4',
                      'ipv6': '仅 IPv6',
                    },
                    compact: true,
                    onChanged: draft.saving
                        ? null
                        : (v) {
                            draft.family = v;
                            draft.changed();
                          },
                  ),
                ),
                row(
                  'interfaceName',
                  '使用网卡',
                  Row(
                    children: [
                      Expanded(
                        child: SelectBox<String>(
                          value: draft.interfaceName,
                          items: interfaceItems,
                          localizeItems: false,
                          compact: true,
                          onChanged: draft.saving
                              ? null
                              : (v) {
                                  draft.interfaceName = v;
                                  draft.changed();
                                },
                        ),
                      ),
                      IconButton(
                        tooltip: tr('刷新网卡列表'),
                        onPressed: draft.saving
                            ? null
                            : draft.refreshInterfaces,
                        icon: const Icon(FIcons.refreshCw, size: 15),
                      ),
                    ],
                  ),
                ),
                row(
                  'stunServers',
                  'STUN 服务器',
                  AppInput(
                    key: const ValueKey('multiplayer-setting-stunServers'),
                    controller: draft.fields['stunServers'],
                    maxLines: 6,
                    compact: true,
                    enabled: !draft.saving,
                  ),
                  description: '每行一个 stun:主机:端口；留空仅尝试直接可达的地址',
                ),
                row(
                  'localPort',
                  '本地 UDP 端口',
                  number('localPort'),
                  description: '0 为自动分配；此端口用于联机通道，不是 Minecraft 游戏端口',
                ),
                row('stunTimeout', 'STUN 超时（秒，1–10）', number('stunTimeout')),
                row(
                  'connectTimeout',
                  '房主直连超时（秒，10–120）',
                  number('connectTimeout'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Surface(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const LText(
                  '房间与游戏发现',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                row(
                  'invitationMinutes',
                  '邀请有效期（分钟，1–10）',
                  number('invitationMinutes'),
                ),
                row('maxPeers', '朋友连接上限（1–16）', number('maxPeers')),
                toggle(
                  'discoverLAN',
                  '自动检测房主的局域网世界',
                  draft.discoverLAN,
                  (v) => draft.discoverLAN = v,
                ),
                toggle(
                  'announceLAN',
                  '在加入者的游戏中发布局域网世界',
                  draft.announceLAN,
                  (v) => draft.announceLAN = v,
                ),
                LText(
                  '关闭自动检测后可在房间中手动指定游戏端口；关闭发布后可使用本机直连地址',
                  style: TextStyle(fontSize: 12, color: c.secondaryText),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (draft.error != null || draft.network.settingsError != null) ...[
            LText(
              draft.error ?? draft.network.settingsError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: AppButton(
              draft.saving
                  ? '正在保存'
                  : draft.saved
                  ? '已保存'
                  : '保存联机设置',
              key: const ValueKey('save-multiplayer-settings'),
              icon: FIcons.save,
              onPressed: draft.saving || !draft.dirty ? null : draft.save,
            ),
          ),
        ],
      );
    },
  );
}
