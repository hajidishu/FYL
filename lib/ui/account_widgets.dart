import 'scrolling.dart';
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/accounts.dart';
import '../core/controller.dart';
import '../core/microsoft_auth.dart';
import '../core/network.dart';
import 'theme.dart';

class SkinAvatar extends StatefulWidget {
  final LauncherAccount? account;
  final double size;
  const SkinAvatar({this.account, this.size = 64, super.key});
  @override
  State<SkinAvatar> createState() => _SkinAvatarState();
}

class _SkinAvatarState extends State<SkinAvatar> {
  static final _cache = <String, Uint8List>{};
  ui.Image? _image;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant SkinAvatar old) {
    super.didUpdateWidget(old);
    if (old.account?.skinUrl != widget.account?.skinUrl ||
        old.account?.kind != widget.account?.kind) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final fallback = (await rootBundle.load(
      'assets/skins/steve.png',
    )).buffer.asUint8List();
    var bytes = fallback;
    final url = widget.account?.online == true ? widget.account?.skinUrl : null;
    if (url != null) {
      final uri = Uri.tryParse(url);
      if (uri != null &&
          uri.host == 'textures.minecraft.net' &&
          ['http', 'https'].contains(uri.scheme)) {
        final secure = uri.replace(scheme: 'https');
        try {
          bytes =
              _cache[secure.toString()] ??
              await (() async {
                final client = HttpClient()
                  ..connectionTimeout = const Duration(seconds: 8);
                try {
                  final response = await (await client.getUrl(
                    secure,
                  )).close().timeout(const Duration(seconds: 10));
                  if (response.statusCode != 200) {
                    throw const HttpException('皮肤暂不可用');
                  }
                  final data = BytesBuilder();
                  await for (final chunk in response.timeout(
                    const Duration(seconds: 10),
                  )) {
                    data.add(chunk);
                    if (data.length > 1024 * 1024) {
                      throw const FormatException('皮肤文件过大');
                    }
                  }
                  final value = data.takeBytes();
                  _cache[secure.toString()] = value;
                  return value;
                } finally {
                  client.close(force: true);
                }
              })();
        } catch (_) {
          bytes = fallback;
        }
      }
    }
    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (_) {
      codec = await ui.instantiateImageCodec(fallback);
    }
    final frame = await codec.getNextFrame();
    codec.dispose();
    if (!mounted || generation != _generation) {
      frame.image.dispose();
      return;
    }
    final old = _image;
    setState(() => _image = frame.image);
    old?.dispose();
  }

  @override
  void dispose() {
    _generation++;
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(widget.size * .18),
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _FacePainter(_image),
    ),
  );
}

class _FacePainter extends CustomPainter {
  final ui.Image? image;
  const _FacePainter(this.image);
  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = const Color(0xFF9B7356),
      );
      return;
    }
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    canvas.drawImageRect(
      image!,
      const Rect.fromLTWH(8, 8, 8, 8),
      Offset.zero & size,
      paint,
    );
    if (image!.width >= 48) {
      canvas.drawImageRect(
        image!,
        const Rect.fromLTWH(40, 8, 8, 8),
        Offset.zero & size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FacePainter old) => old.image != image;
}

class AccountBadge extends StatelessWidget {
  final bool online;
  const AccountBadge({required this.online, super.key});
  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    final color = online
        ? c.accent
        : c.dark
        ? const Color(0xFF9DBEF2)
        : const Color(0xFF486DA2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(5),
      ),
      child: LText(
        online ? '正版账号' : '离线账号',
        style: TextStyle(color: color, fontSize: 10),
      ),
    );
  }
}

class HomeAccountCard extends StatefulWidget {
  final LauncherController controller;
  final VoidCallback onOpenSettings;
  const HomeAccountCard({
    required this.controller,
    required this.onOpenSettings,
    super.key,
  });
  @override
  State<HomeAccountCard> createState() => _HomeAccountCardState();
}

class _HomeAccountCardState extends State<HomeAccountCard> {
  bool hovering = false;
  void manage() => unawaited(
    showDialog<void>(
      context: context,
      builder: (_) => AccountManagerDialog(
        controller: widget.controller,
        onOpenSettings: widget.onOpenSettings,
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final account = widget.controller.activeAccount;
    final c = LauncherColors.of(context);
    return Surface(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LText('当前账号', style: TextStyle(color: c.muted, fontSize: 11)),
          const SizedBox(height: 22),
          Center(
            child: MouseRegion(
              onEnter: (_) => setState(() => hovering = true),
              onExit: (_) => setState(() => hovering = false),
              child: LTooltip(
                message: account == null ? '添加账号' : '切换账号',
                child: Semantics(
                  button: true,
                  label: '管理游戏账号',
                  child: InkWell(
                    onTap: manage,
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox.square(
                      dimension: 72,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          SkinAvatar(account: account, size: 72),
                          if (hovering)
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: .6),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              alignment: Alignment.center,
                              child: LText(
                                account == null ? '添加账号' : '切换账号',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            account?.username ?? tr('尚未添加账号'),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 9),
          if (account != null)
            Center(child: AccountBadge(online: account.online)),
          const SizedBox(height: 20),
          AppButton(
            '切换账号',
            key: const ValueKey('switch-account'),
            icon: FIcons.users,
            secondary: true,
            small: true,
            onPressed: manage,
          ),
        ],
      ),
    );
  }
}

class AccountManagerDialog extends StatefulWidget {
  final LauncherController controller;
  final VoidCallback onOpenSettings;
  const AccountManagerDialog({
    required this.controller,
    required this.onOpenSettings,
    super.key,
  });
  @override
  State<AccountManagerDialog> createState() => _AccountManagerDialogState();
}

class _AccountManagerDialogState extends State<AccountManagerDialog> {
  final name = TextEditingController();
  bool addingOffline = false;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> choose(LauncherAccount account) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.switchAccount(account);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> create() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.controller.addOfflineAccount(name.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() async {
    if (widget.controller.settings.microsoftClientId.trim().isEmpty) {
      setState(() => error = '尚未配置微软应用 Client ID。请先在设置 → 通用中填写 FYL 的应用 ID。');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => MicrosoftLoginDialog(controller: widget.controller),
    );
    if (ok == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = LauncherColors.of(context);
      return AlertDialog(
        title: const LText(
          '选择游戏账号',
          style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 480,
          child: AppScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.controller.accounts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    child: LText(
                      '还没有账号，请在下方添加。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.muted),
                    ),
                  ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 250),
                  child: AppScrollView(
                    child: Column(
                      children: [
                        for (final account in widget.controller.accounts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InkWell(
                              onTap: busy ? null : () => choose(account),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color:
                                      widget.controller.activeAccount?.id ==
                                          account.id
                                      ? c.accentBackground
                                      : c.raised,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    SkinAvatar(account: account, size: 36),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        account.username,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    AccountBadge(online: account.online),
                                    if (widget.controller.activeAccount?.id ==
                                        account.id) ...[
                                      const SizedBox(width: 10),
                                      Icon(
                                        FIcons.check,
                                        size: 15,
                                        color: c.accent,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    AppButton(
                      '添加离线账号',
                      icon: FIcons.userPlus,
                      secondary: true,
                      small: true,
                      onPressed: busy
                          ? null
                          : () => setState(() => addingOffline = true),
                    ),
                    AppButton(
                      '微软账号登录',
                      icon: FIcons.logIn,
                      small: true,
                      onPressed: busy ? null : login,
                    ),
                  ],
                ),
                if (addingOffline) ...[
                  const SizedBox(height: 20),
                  AppInput(
                    controller: name,
                    label: '游戏用户名',
                    hint: '3–16 位英文字母、数字或下划线',
                  ),
                  const SizedBox(height: 12),
                  AppButton(
                    busy ? '正在创建…' : '创建并使用',
                    onPressed: busy ? null : create,
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 16),
                  LText(
                    error!,
                    style: TextStyle(
                      color: c.dark
                          ? const Color(0xFFEF9990)
                          : Colors.red.shade800,
                      fontSize: 12,
                    ),
                  ),
                  if (widget.controller.settings.microsoftClientId.isEmpty)
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onOpenSettings();
                      },
                      child: const LText('前往设置'),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          AppButton(
            '关闭',
            secondary: true,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      );
    },
  );
}

class MicrosoftLoginDialog extends StatefulWidget {
  final LauncherController controller;
  const MicrosoftLoginDialog({required this.controller, super.key});
  @override
  State<MicrosoftLoginDialog> createState() => _MicrosoftLoginDialogState();
}

class _MicrosoftLoginDialogState extends State<MicrosoftLoginDialog> {
  late final auth = widget.controller.authFactory();
  final token = CancellationToken();
  DeviceLoginCode? code;
  String? error;
  bool appRegistrationRejected = false;
  @override
  void initState() {
    super.initState();
    unawaited(_login());
  }

  Future<void> _login() async {
    try {
      final clientId = widget.controller.settings.microsoftClientId.trim();
      final value = await auth.begin(clientId, token);
      if (!mounted) return;
      setState(() => code = value);
      final result = await auth.complete(clientId, value, token);
      token.check();
      await widget.controller.addMicrosoftAccount(result);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted && !token.cancelled) {
        setState(() {
          error = e is StateError ? e.message.toString() : '$e';
          appRegistrationRejected = e is MinecraftAppRegistrationException;
        });
      }
    }
  }

  Future<void> _openPage(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Keep browser failures in the login dialog rather than an unhandled future.
    }
    if (!opened && mounted) {
      setState(() {
        error = '${error == null ? '' : '$error\n\n'}无法打开浏览器，请手动访问 $uri';
      });
    }
  }

  @override
  void dispose() {
    token.cancel();
    auth.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = LauncherColors.of(context);
    return AlertDialog(
      scrollable: true,
      title: const LText('微软账号登录', style: TextStyle(fontSize: 19)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (error != null) ...[
              LSelectableText(error!, style: const TextStyle(fontSize: 12)),
              if (appRegistrationRejected) ...[
                const SizedBox(height: 16),
                AppButton(
                  '查看服务说明',
                  icon: FIcons.externalLink,
                  secondary: true,
                  small: true,
                  onPressed: () =>
                      _openPage(MinecraftAppRegistrationException.helpUri),
                ),
              ],
            ] else if (code == null)
              const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              LText(
                '在微软页面输入此验证码并完成授权。FYL 不会收集你的微软密码。',
                style: TextStyle(color: c.muted, fontSize: 12, height: 1.7),
              ),
              const SizedBox(height: 22),
              SelectableText(
                code!.userCode,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  letterSpacing: 4,
                  color: c.accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 22),
              AppButton(
                '打开微软登录页面',
                icon: FIcons.externalLink,
                onPressed: () => _openPage(code!.verificationUri),
              ),
              const SizedBox(height: 10),
              AppButton(
                '复制验证码',
                icon: FIcons.copy,
                secondary: true,
                small: true,
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: code!.userCode)),
              ),
              const SizedBox(height: 18),
              LText(
                '正在等待浏览器中的登录结果…',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.muted, fontSize: 11),
              ),
            ],
          ],
        ),
      ),
      actions: [
        AppButton(
          error == null ? '取消' : '关闭',
          secondary: true,
          onPressed: () => Navigator.pop(context, false),
        ),
      ],
    );
  }
}
