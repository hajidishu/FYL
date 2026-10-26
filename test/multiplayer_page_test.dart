import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/controller.dart';
import 'package:free_your_launcher/core/models.dart';
import 'package:free_your_launcher/core/multiplayer.dart';
import 'package:free_your_launcher/l10n/app_localizations.dart';
import 'package:free_your_launcher/main.dart';

import 'multiplayer_test.dart' show invitation;

class RoomFixture extends MultiplayerController {
  bool inSession = false;
  bool reusable = false;
  int hosts = 0, stops = 0;
  final ports = <int>[];
  String? joined, answered, address;
  Completer<void>? preparation;
  @override
  bool get active => inSession;
  @override
  String? get gameAddress => address;

  @override
  Future<void> host() async {
    hosts++;
    isHost = true;
    inSession = true;
    state = MultiplayerState.starting;
    notifyListeners();
    if (preparation != null) {
      await preparation!.future;
      return;
    }
    ticket = invitation(version: reusable ? 2 : 1);
    expires = DateTime.now().add(const Duration(minutes: 5));
    multiRoom = accepting = reusable;
    state = reusable
        ? MultiplayerState.hosting
        : MultiplayerState.waitingAnswer;
    notifyListeners();
  }

  @override
  Future<void> join(String value) async {
    joined = value;
    lastInvitation = value;
    isHost = false;
    inSession = true;
    state = MultiplayerState.connecting;
    ticket = invitation(
      kind: 'answer',
      version: value.startsWith('FYL2:') ? 2 : 1,
    );
    notifyListeners();
  }

  @override
  void answer(String value) {
    answered = value;
    if (multiRoom) {
      final number = peers.length + 1;
      peers['friend-$number'] = MultiplayerPeer(
        id: 'friend-$number',
        number: number,
        state: MultiplayerState.connected,
      );
      notifyListeners();
      return;
    }
    state = MultiplayerState.connected;
    notifyListeners();
  }

  void world({required bool host}) {
    inSession = true;
    isHost = host;
    state = MultiplayerState.connected;
    gameName = 'A world with friends';
    gamePort = 25565;
    address = '127.0.0.1:45000';
    notifyListeners();
  }

  @override
  void sharePort(int value) => ports.add(value);

  @override
  void pauseInvitation() {
    accepting = false;
    notifyListeners();
  }

  @override
  void refreshInvitation() {
    accepting = true;
    invitationExpired = false;
    notifyListeners();
  }

  @override
  void removePeer(String id) {
    peers.remove(id);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    inSession = false;
    state = MultiplayerState.idle;
    ticket = error = address = null;
    gamePort = 0;
    multiRoom = accepting = false;
    peers.clear();
    final pending = preparation;
    preparation = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    notifyListeners();
  }
}

class PageFixture extends LauncherController {
  final RoomFixture room;
  PageFixture(this.room)
    : super(
        supportDirectory: Directory.systemTemp.path,
        platform: const HostPlatform('windows', 'x86_64'),
      );
  @override
  MultiplayerController get multiplayer => room;
}

const preview = bool.fromEnvironment('FYL_UI_PREVIEW');
const screen = ValueKey('multiplayer-test-screen');

Future<void> showPage(
  WidgetTester tester,
  PageFixture controller, {
  Size size = const Size(1180, 780),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: true);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: screen,
      child: LauncherApp(controller: controller, nativeWindow: false),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('navigation-4')));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}

Future<void> press(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> snapshot(WidgetTester tester, String name) async {
  if (!preview) return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(screen),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final directory = Directory('build/multiplayer-previews');
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(
      data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;
  setUpAll(() async {
    if (preview && Platform.isWindows) {
      final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
      for (final family in ['Microsoft YaHei UI', 'Noto Sans CJK SC']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
      final icons = FontLoader('packages/forui_assets/ForuiLucideIcons')
        ..addFont(rootBundle.load('packages/forui_assets/assets/lucide.ttf'));
      await icons.load();
    }
  });
  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return clipboard == null ? null : {'text': clipboard};
          }
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets(
    'host exchanges information then gets an actionable world guide',
    (tester) async {
      final room = RoomFixture();
      await showPage(tester, PageFixture(room));
      await snapshot(tester, '01-host-start');
      await press(tester, 'multiplayer-start');
      expect(room.hosts, 1);
      expect(find.text('先把邀请发给朋友'), findsOneWidget);
      expect(find.text(room.ticket!), findsNothing);
      await snapshot(tester, '02-host-exchange');
      await press(tester, 'multiplayer-copy-ticket');
      expect(clipboard, room.ticket);
      expect(find.text('已复制邀请'), findsOneWidget);
      final reply = clipboard = invitation(kind: 'answer');
      await press(tester, 'multiplayer-connect');
      expect(room.answered, reply);
      expect(find.text('接下来，开放你的游戏世界'), findsOneWidget);
      expect(find.text('按 Esc，选择“对局域网开放”'), findsOneWidget);
      await tester.tap(find.text('前往开始游戏'));
      await tester.pumpAndSettle();
      expect(find.text('接下来，开放你的游戏世界'), findsNothing);
      expect(room.connected, isTrue);
      await tester.tap(find.byKey(const ValueKey('navigation-4')));
      await tester.pumpAndSettle();
      room.world(host: true);
      await tester.pumpAndSettle();
      expect(find.text('世界已开放，朋友可以加入了'), findsOneWidget);
      expect(find.text(room.gameAddress!), findsNothing);
      expect(tester.takeException(), isNull);
      await snapshot(tester, '03-host-world');
    },
  );

  testWidgets(
    'guest can paste once, send a reply, and find the local fallback',
    (tester) async {
      final room = RoomFixture();
      final controller = PageFixture(room)..settings.theme = 'light';
      await showPage(tester, controller);
      await press(tester, 'multiplayer-role-guest');
      await snapshot(tester, '04-guest-start-light');
      final offer = clipboard = invitation();
      await press(tester, 'multiplayer-start');
      expect(room.joined, offer);
      expect(find.text('把回应发给房主'), findsOneWidget);
      await press(tester, 'multiplayer-copy-ticket');
      expect(clipboard, room.ticket);
      expect(find.text('等待房主导入回应，连接成功后会自动进入下一步'), findsOneWidget);
      room.state = MultiplayerState.connected;
      room.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('已连接，等待房主开放世界'), findsOneWidget);
      room.world(host: false);
      await tester.pumpAndSettle();
      expect(find.text('世界已准备好，可以加入了'), findsOneWidget);
      await tester.tap(find.text('没有看到局域网世界？'));
      await tester.pumpAndSettle();
      await press(tester, 'multiplayer-copy-address');
      expect(clipboard, room.gameAddress);
      expect(find.text('此地址只用于你这台电脑，不需要发给朋友'), findsOneWidget);
      expect(find.text('已复制地址'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await snapshot(tester, '05-guest-world-light');
    },
  );

  testWidgets('wrong information and an empty clipboard explain what to send', (
    tester,
  ) async {
    final room = RoomFixture();
    await showPage(tester, PageFixture(room));
    await press(tester, 'multiplayer-role-guest');
    await press(tester, 'multiplayer-start');
    expect(find.textContaining('剪贴板里没有联机信息，请先复制朋友发来的内容'), findsOneWidget);
    clipboard = invitation(kind: 'answer');
    await press(tester, 'multiplayer-start');
    expect(find.textContaining('这是回应信息，请让朋友发送邀请'), findsOneWidget);
    expect(room.joined, isNull);
    await press(tester, 'multiplayer-role-host');
    await press(tester, 'multiplayer-start');
    clipboard = room.ticket;
    await press(tester, 'multiplayer-connect');
    expect(find.textContaining('这是邀请信息，请让朋友发送回应'), findsOneWidget);
    expect(room.answered, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pending startup can be cancelled from the page', (
    tester,
  ) async {
    final room = RoomFixture()..preparation = Completer<void>();
    await showPage(tester, PageFixture(room));
    await press(tester, 'multiplayer-start');
    expect(find.text('正在准备邀请'), findsOneWidget);
    await press(tester, 'multiplayer-disconnect');
    expect(room.stops, 1);
    expect(room.active, isFalse);
    expect(find.text('创建邀请'), findsOneWidget);
    expect(find.text('我是房主'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual sharing validates the port and can restore discovery', (
    tester,
  ) async {
    final room = RoomFixture()
      ..inSession = true
      ..state = MultiplayerState.connected;
    await showPage(tester, PageFixture(room));
    await tester.tap(find.text('没有自动找到游戏？'));
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('multiplayer-port')),
      matching: find.byType(EditableText),
    );
    Future<void> use(String value) async {
      await tester.enterText(field, value);
      await tester.ensureVisible(find.text('使用此端口'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用此端口'));
      await tester.pumpAndSettle();
    }

    await use('70000');
    expect(room.ports, isEmpty);
    expect(find.textContaining('游戏端口无效'), findsOneWidget);
    await use('25565');
    expect(room.ports, [25565]);
    expect(
      find.byKey(const ValueKey('multiplayer-guidance-error')),
      findsNothing,
    );
    await tester.ensureVisible(find.text('恢复自动识别'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复自动识别'));
    await tester.pumpAndSettle();
    expect(room.ports, [25565, 0]);
    expect(tester.widget<EditableText>(field).controller.text, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed guests retry as guests and never create a host room', (
    tester,
  ) async {
    final room = RoomFixture()
      ..isHost = false
      ..state = MultiplayerState.failed
      ..error = multiplayerError('direct_failed');
    await showPage(tester, PageFixture(room));
    expect(find.text('重新粘贴邀请'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('multiplayer-guidance-error')),
      findsOneWidget,
    );
    await press(tester, 'multiplayer-restart');
    expect(room.hosts, 0);
    expect(find.text('先粘贴朋友发来的邀请'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'one room invitation accepts several replies and keeps its controls',
    (tester) async {
      final room = RoomFixture()..reusable = true;
      await showPage(tester, PageFixture(room));
      await press(tester, 'multiplayer-start');
      await press(tester, 'multiplayer-copy-ticket');
      final shared = clipboard;
      expect(find.text('已连接 0 位朋友'), findsOneWidget);
      for (var i = 1; i <= 3; i++) {
        clipboard = invitation(version: 2, kind: 'answer');
        await press(tester, 'multiplayer-connect');
        expect(find.text('已连接 $i 位朋友'), findsOneWidget);
        expect(room.ticket, shared);
      }
      expect(find.text('朋友 3'), findsOneWidget);
      await press(tester, 'remove-peer-friend-2');
      expect(find.text('已连接 2 位朋友'), findsOneWidget);
      expect(room.peers.keys, ['friend-1', 'friend-3']);
      await tester.ensureVisible(find.text('停止接纳新人'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停止接纳新人'));
      await tester.pumpAndSettle();
      expect(room.accepting, isFalse);
      expect(find.text('已停止接纳新人，在线朋友不受影响'), findsOneWidget);
      await tester.tap(find.text('重新生成邀请'));
      await tester.pumpAndSettle();
      expect(room.accepting, isTrue);
      expect(room.peers, hasLength(2));
      expect(tester.takeException(), isNull);
      await snapshot(tester, '07-shared-room');
    },
  );

  testWidgets(
    'a guest retries with the same room invitation and generates a new reply',
    (tester) async {
      final shared = invitation(version: 2);
      final room = RoomFixture()
        ..isHost = false
        ..state = MultiplayerState.failed
        ..lastInvitation = shared;
      await showPage(tester, PageFixture(room));
      expect(find.text('重新生成回应'), findsOneWidget);
      await press(tester, 'multiplayer-restart');
      expect(room.joined, shared);
      expect(room.hosts, 0);
      expect(find.text('把回应发给房主'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in launcherLanguages.keys) {
    testWidgets(
      'compact $language layout handles scaled text and every stage',
      (tester) async {
        final room = RoomFixture();
        final controller = PageFixture(room)
          ..settings.language = language
          ..settings.accentColor = 0x7c3aed;
        await showPage(
          tester,
          controller,
          size: const Size(800, 600),
          textScale: 1.25,
        );
        await press(tester, 'multiplayer-start');
        expect(tester.takeException(), isNull);
        await snapshot(tester, '06-compact-$language');
        clipboard = invitation(kind: 'answer');
        await press(tester, 'multiplayer-connect');
        expect(tester.takeException(), isNull);
        room.world(host: true);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await press(tester, 'multiplayer-disconnect');
        await press(tester, 'multiplayer-role-guest');
        clipboard = invitation();
        await press(tester, 'multiplayer-start');
        expect(tester.takeException(), isNull);
        room.world(host: false);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await press(tester, 'multiplayer-disconnect');
        room.reusable = true;
        await press(tester, 'multiplayer-role-host');
        await press(tester, 'multiplayer-start');
        expect(tester.takeException(), isNull);
        clipboard = invitation(version: 2, kind: 'answer');
        await press(tester, 'multiplayer-connect');
        expect(tester.takeException(), isNull);
        await snapshot(tester, '08-compact-shared-$language');
      },
    );
  }
}
