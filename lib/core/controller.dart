import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'minecraft.dart';
import 'game_log.dart';
import 'models.dart';
import 'network.dart';
import 'accounts.dart';
import 'account_store.dart';
import 'microsoft_auth.dart';
import 'install_options.dart';
import 'content_installer.dart';
import 'community_models.dart';
import 'instance_tools.dart';
import 'local_mods.dart';
import 'pack_import.dart' show ensurePackParents;

class LauncherController extends ChangeNotifier {
  final String supportDirectory;
  final HostPlatform platform;
  final AccountTokenStore tokenStore;
  final MicrosoftAuth Function() authFactory;
  final SecureAccountTokenStore appSecrets;
  static const _curseforgeKey = 'settings.curseforge-api-key';
  late final content = ContentInstaller(
    platform: platform,
    supportDirectory: supportDirectory,
    settings: () => settings.copy(),
    busy: () => installing,
    checkModTarget: (target) {
      final current = editableInstance(target.id);
      if (!p.equals(current.gameDirectory, target.gameDirectory) ||
          current.version != target.version) {
        throw StateError('版本目录已变化，请重新选择目标版本。');
      }
    },
    checkPackTarget: (root, isolated) =>
        assertGameDirectoryAvailable(isolated ? null : root),
    versionInUse: (directory) =>
        instances.any((i) => p.equals(i.versionDirectory, directory)),
    onChanged: _throttledNotify,
    onInstalled: (instance) async {
      final previous = selectedId;
      instances.insert(0, instance);
      selectedId = instance.id;
      try {
        await _save();
      } catch (_) {
        instances.remove(instance);
        selectedId = previous;
        rethrow;
      }
      notice = '${instance.name} 安装完成';
      notifyListeners();
    },
  );
  final accounts = <LauncherAccount>[];
  String? activeAccountId;
  late LauncherSettings settings;
  final instances = <GameInstance>[];
  final versions = <MinecraftVersion>[];
  final tasks = <InstallTask>[];
  final logs = <String>[];
  String? selectedId;
  String? errorMessage;
  String? notice;
  String? latestRelease;
  bool loadingVersions = false;
  bool manifestFromCache = false;
  bool preparingLaunch = false;
  String? instanceOperation;
  CancellationToken? _instanceToken;
  Process? gameProcess;
  String? runningInstanceId;
  String? lastLogPath;
  int? lastExitCode;
  CancellationToken? _installToken;
  OfficialNetwork? _manifestNetwork;
  Timer? _notifyTimer;
  Timer? _usernameTimer;
  Future<void> _saveTail = Future.value();
  bool _disposed = false;

  LauncherController({
    required this.supportDirectory,
    required this.platform,
    AccountTokenStore? tokenStore,
    MicrosoftAuth Function()? authFactory,
    SecureAccountTokenStore? appSecrets,
  }) : appSecrets =
           appSecrets ??
           SecureAccountTokenStore(supportDirectory: supportDirectory),
       tokenStore =
           tokenStore ??
           SecureAccountTokenStore(supportDirectory: supportDirectory),
       authFactory = authFactory ?? MicrosoftAuth.new {
    settings = LauncherSettings(
      gameRoot: p.join(supportDirectory, '.minecraft'),
    );
  }

  File get _config => File(p.join(supportDirectory, 'launcher.json'));
  LauncherAccount? get activeAccount {
    for (final account in accounts) {
      if (account.id == activeAccountId) return account;
    }
    return accounts.isEmpty ? null : accounts.first;
  }

  bool get installing =>
      instanceOperation != null ||
      tasks.any((t) => t.status == TaskStatus.running) ||
      content.tasks.any((t) => t.state == ContentTaskState.running);
  bool get running => preparingLaunch || gameProcess != null;
  String get activityText {
    if (preparingLaunch) return '正在准备启动';
    if (instanceOperation != null) return '正在$instanceOperation';
    if (tasks.any((t) => t.status == TaskStatus.running)) return '正在安装游戏';
    if (content.tasks.any((t) => t.state == ContentTaskState.running)) {
      return '正在下载社区资源';
    }
    return gameProcess != null ? 'Minecraft 正在运行' : '准备就绪';
  }

  GameInstance? get selectedInstance {
    for (final instance in instances) {
      if (instance.id == selectedId) return instance;
    }
    return instances.isEmpty ? null : instances.first;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void _throttledNotify() {
    if (_disposed) return;
    _notifyTimer ??= Timer(const Duration(milliseconds: 120), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  Future<void> initialize() async {
    var loadCurseForgeKey = false;
    await Directory(supportDirectory).create(recursive: true);
    if (await _config.exists() || await File('${_config.path}.bak').exists()) {
      Json? data;
      for (final path in [_config.path, '${_config.path}.bak']) {
        try {
          data = jsonDecode(await File(path).readAsString()) as Json;
          break;
        } catch (_) {
          /* Try the backup. */
        }
      }
      if (data == null) {
        errorMessage =
            '设置文件无法读取。原文件已保留，请检查 $supportDirectory 中的 launcher.json。';
      } else {
        loadCurseForgeKey = data['hasCurseforgeApiKey'] == true;
        settings = LauncherSettings.fromJson(
          data['settings'] as Json? ?? {},
          settings.gameRoot,
        );
        for (final json in data['instances'] as List<dynamic>? ?? []) {
          try {
            instances.add(GameInstance.fromJson(json as Json));
          } catch (_) {
            errorMessage = '部分版本记录无法读取，请检查配置文件。';
          }
        }
        selectedId = data['selectedId'] as String?;
        for (final raw in data['accounts'] as List<dynamic>? ?? []) {
          try {
            accounts.add(LauncherAccount.fromJson(raw as Json));
          } catch (_) {
            errorMessage = '部分账户记录无法读取，请在首页重新添加。';
          }
        }
        activeAccountId = data['activeAccountId'] as String?;
        if (accounts.isEmpty && validateUsername(settings.username) == null) {
          final migrated = LauncherAccount.offline(settings.username);
          accounts.add(migrated);
          activeAccountId = migrated.id;
          await _save();
        }
        if (activeAccount != null) settings.username = activeAccount!.username;
      }
    }
    if (loadCurseForgeKey) {
      try {
        settings.curseforgeApiKey =
            await appSecrets.readValue(_curseforgeKey) ??
            settings.curseforgeApiKey;
      } catch (_) {
        errorMessage = '无法读取 CurseForge 访问密钥，请在设置中重新填写。';
      }
    }
    notifyListeners();
  }

  Future<void> _save() {
    final data = <String, dynamic>{
      'schemaVersion': 2,
      'settings': settings.toJson(),
      'instances': instances.map((i) => i.toJson()).toList(),
      'selectedId': selectedId,
      'accounts': accounts.map((account) => account.toJson()).toList(),
      'activeAccountId': activeAccountId,
      'hasCurseforgeApiKey': settings.curseforgeApiKey.isNotEmpty,
    };
    final next = _saveTail
        .catchError((Object _) {})
        .then((_) => writeJson(_config, data));
    _saveTail = next;
    return next;
  }

  Future<void> saveSettings(LauncherSettings value) async {
    final error = value.validate();
    if (error != null) throw ArgumentError(error);
    final old = settings;
    settings = value.copy();
    if (activeAccount != null) settings.username = activeAccount!.username;
    try {
      if (old.curseforgeApiKey != value.curseforgeApiKey) {
        if (value.curseforgeApiKey.isEmpty) {
          await appSecrets.delete(_curseforgeKey);
        } else {
          await appSecrets.writeValue(_curseforgeKey, value.curseforgeApiKey);
        }
      }
      await _save();
    } catch (_) {
      settings = old;
      if (old.curseforgeApiKey != value.curseforgeApiKey) {
        try {
          if (old.curseforgeApiKey.isEmpty) {
            await appSecrets.delete(_curseforgeKey);
          } else {
            await appSecrets.writeValue(_curseforgeKey, old.curseforgeApiKey);
          }
        } catch (_) {
          /* Preserve the original save error. */
        }
      }
      rethrow;
    }
    notice = '设置已保存';
    notifyListeners();
  }

  Future<void> addOfflineAccount(String username) async {
    await _storeAccount(LauncherAccount.offline(username));
  }

  Future<void> addMicrosoftAccount(MicrosoftLoginResult result) async {
    await tokenStore.write(result.account.id, result.tokens);
    await _storeAccount(result.account);
  }

  Future<void> _storeAccount(
    LauncherAccount account, {
    bool select = true,
  }) async {
    final previous = accounts.toList();
    final previousId = activeAccountId;
    final previousName = settings.username;
    final index = accounts.indexWhere((entry) => entry.id == account.id);
    if (index < 0) {
      accounts.add(account);
    } else {
      accounts[index] = account;
    }
    if (select) activeAccountId = account.id;
    settings.username = activeAccount?.username ?? previousName;
    try {
      await _save();
    } catch (_) {
      accounts
        ..clear()
        ..addAll(previous);
      activeAccountId = previousId;
      settings.username = previousName;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> switchAccount(LauncherAccount account) async {
    if (!accounts.any((entry) => entry.id == account.id)) {
      throw ArgumentError('账户不存在');
    }
    await _storeAccount(account);
  }

  Future<GameSession> prepareSession() async {
    final account = activeAccount;
    if (account == null) throw StateError('请先在首页添加或选择账户。');
    if (!account.online) {
      return GameSession(username: account.username, uuid: account.uuid);
    }
    AccountTokens? tokens;
    try {
      tokens = await tokenStore.read(account.id);
    } catch (_) {
      throw StateError('无法读取系统凭据，请在首页重新登录该微软账户。');
    }
    if (tokens == null) throw StateError('此正版账户需要重新登录，请在首页添加微软账户以更新登录。');
    var sessionAccount = account;
    if (!tokens.valid) {
      final auth = authFactory();
      try {
        final refreshed = await auth.refresh(tokens, CancellationToken());
        if (refreshed.account.uuid != account.uuid) {
          throw StateError('刷新后的账户身份不一致，请重新登录。');
        }
        await tokenStore.write(account.id, refreshed.tokens);
        await _storeAccount(refreshed.account, select: false);
        sessionAccount = refreshed.account;
        tokens = refreshed.tokens;
      } finally {
        auth.close();
      }
    }
    return GameSession(
      username: sessionAccount.username,
      uuid: account.uuid,
      online: true,
      accessToken: tokens.accessToken,
      clientId: tokens.clientId,
      xuid: tokens.xuid,
    );
  }

  void setUsername(String value) {
    settings.username = value;
    _usernameTimer?.cancel();
    _usernameTimer = Timer(const Duration(milliseconds: 400), () async {
      try {
        await _save();
      } catch (e) {
        errorMessage = '用户名保存失败：$e';
        notifyListeners();
      }
    });
    notifyListeners();
  }

  Future<void> selectInstance(GameInstance instance) async {
    selectedId = instance.id;
    notifyListeners();
    try {
      await _save();
    } catch (e) {
      errorMessage = '保存选择失败：$e';
      notifyListeners();
    }
  }

  Future<void> saveInstanceJava(
    String instanceId,
    InstanceJavaMode mode,
    String path,
  ) async {
    if (mode == InstanceJavaMode.custom && path.trim().isEmpty) {
      throw ArgumentError('请选择 Java 可执行文件。');
    }
    final index = instances.indexWhere((instance) => instance.id == instanceId);
    if (index < 0) throw StateError('此版本已不存在。');
    await saveInstance(instances[index].withJava(mode, path));
  }

  Future<void> saveInstance(GameInstance value) async {
    if (instanceOperation != null) throw StateError('请等待当前任务完成后再保存版本设置。');
    final index = instances.indexWhere((i) => i.id == value.id);
    if (index < 0) throw StateError('此版本已不存在。');
    final nameError = validateVersionName(value.name);
    if (nameError != null) throw ArgumentError(nameError);
    final previous = instances[index];
    if (value.root != previous.root ||
        value.version != previous.version ||
        value.isolated != previous.isolated) {
      throw ArgumentError('请通过目录切换功能更改版本目录。');
    }
    final error = value.effectiveSettings(settings).validate();
    if (error != null) throw ArgumentError(error);
    final renaming = previous.name != value.name;
    if (renaming) {
      editableInstance(value.id);
      instanceOperation = '重命名版本';
      notifyListeners();
    }
    var renamed = false;
    try {
      if (renaming) renamed = await renameVersionDirectory(previous, value);
      instances[index] = value;
      await _save();
      if (renaming) {
        String relocated(String path) =>
            p.isWithin(previous.versionDirectory, path)
            ? p.join(
                value.versionDirectory,
                p.relative(path, from: previous.versionDirectory),
              )
            : path;
        if (lastLogPath != null) lastLogPath = relocated(lastLogPath!);
        for (final task in content.tasks) {
          if (task.destination != null) {
            task.destination = relocated(task.destination!);
          }
        }
      }
    } catch (_) {
      instances[index] = previous;
      if (renamed) await renameVersionDirectory(value, previous);
      rethrow;
    } finally {
      if (renaming) {
        instanceOperation = null;
        notifyListeners();
      }
    }
    notifyListeners();
  }

  GameInstance editableInstance(String id) {
    final instance = instances.where((i) => i.id == id).firstOrNull;
    if (instance == null) throw StateError('此版本已不存在。');
    if (installing) throw StateError('请等待当前任务完成。');
    if (preparingLaunch ||
        runningInstanceId == id ||
        gameProcess != null &&
            instances.any(
              (i) =>
                  i.id == runningInstanceId &&
                  p.equals(i.gameDirectory, instance.gameDirectory),
            )) {
      throw StateError('请先关闭使用此目录的游戏。');
    }
    return instance;
  }

  void assertGameDirectoryAvailable(String? directory) {
    if (preparingLaunch ||
        directory != null &&
            gameProcess != null &&
            instances.any(
              (i) =>
                  i.id == runningInstanceId &&
                  p.equals(i.gameDirectory, directory),
            )) {
      throw StateError('请先关闭使用此游戏目录的游戏。');
    }
  }

  Future<void> changeInstanceIsolation(
    String id,
    bool isolated, {
    bool copyData = false,
  }) async {
    final original = editableInstance(id);
    if (original.isolated == isolated) return;
    final updated = original.copyWith(isolated: isolated);
    if (!p.equals(
          p.normalize(original.root),
          p.normalize(updated.gameDirectory),
        ) &&
        !p.isWithin(
          p.normalize(original.root),
          p.normalize(updated.gameDirectory),
        )) {
      throw const FormatException('版本目录越界。');
    }
    instanceOperation = '切换游戏目录';
    final token = _instanceToken = CancellationToken();
    notifyListeners();
    try {
      if (copyData) await copyInstanceData(original, updated, token);
      final index = instances.indexWhere((i) => i.id == id);
      instances[index] = updated;
      try {
        await _save();
      } catch (_) {
        instances[index] = original;
        rethrow;
      }
    } finally {
      instanceOperation = null;
      _instanceToken = null;
      notifyListeners();
    }
  }

  Future<String?> removeInstance(String id, {bool moveData = false}) async {
    final instance = editableInstance(id);
    instanceOperation = '移除版本';
    notifyListeners();
    try {
      return await _removeInstanceRecord(instance, moveData: moveData);
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<String?> _removeInstanceRecord(
    GameInstance instance, {
    required bool moveData,
  }) async {
    final id = instance.id;
    final index = instances.indexOf(instance);
    final oldSelection = selectedId;
    String? moved;
    if (moveData && await Directory(instance.versionDirectory).exists()) {
      final expected = instance.versionDirectory;
      if (!p.equals(
            p.normalize(expected),
            p.normalize(instance.versionDirectory),
          ) ||
          await FileSystemEntity.type(expected, followLinks: false) !=
              FileSystemEntityType.directory) {
        throw const FormatException('版本目录无效，无法移走数据。');
      }
      moved = safeJoin(
        p.join(instance.root, '.fyl-trash'),
        '${DateTime.now().microsecondsSinceEpoch}-${instance.name}',
      );
      await ensurePackParents(instance.root, moved);
      await Directory(expected).rename(moved);
    }
    instances.removeAt(index);
    if (selectedId == id) selectedId = instances.firstOrNull?.id;
    try {
      await _save();
    } catch (_) {
      instances.insert(index, instance);
      selectedId = oldSelection;
      if (moved != null) {
        await Directory(moved).rename(instance.versionDirectory);
      }
      rethrow;
    }
    notice = moved == null ? '版本已从列表移除，游戏文件已保留' : '版本已移除，游戏数据保留在 $moved';
    notifyListeners();
    return moved;
  }

  Future<void> updateMods(
    String id,
    List<LocalMod> mods, {
    bool? enabled,
    bool remove = false,
  }) async {
    final instance = editableInstance(id);
    instanceOperation = '整理 Mod';
    notifyListeners();
    try {
      if (remove) {
        final location = await trashLocalMods(instance, mods);
        notice = 'Mod 已移至 $location';
      } else {
        await setModsEnabled(instance, mods, enabled!);
      }
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<void> addLocalMods(
    String id,
    List<String> paths, {
    bool replace = false,
  }) async {
    final instance = editableInstance(id);
    instanceOperation = '安装本地 Mod';
    notifyListeners();
    try {
      await importLocalMods(instance, paths, replace: replace);
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<int> exportPack(
    String id,
    String path, {
    required Set<String> folders,
    required String version,
    bool gameOptions = true,
    void Function(int, int)? onProgress,
  }) async {
    final instance = editableInstance(id);
    instanceOperation = '导出整合包';
    final token = _instanceToken = CancellationToken();
    notifyListeners();
    try {
      return await exportInstancePack(
        instance,
        path,
        token,
        folders: folders,
        version: version,
        gameOptions: gameOptions,
        onProgress: onProgress,
      );
    } finally {
      instanceOperation = null;
      _instanceToken = null;
      notifyListeners();
    }
  }

  Future<void> repairInstance(String id) async {
    final instance = editableInstance(id);
    instanceOperation = '修复版本';
    final token = _instanceToken = CancellationToken();
    notifyListeners();
    final snapshot = instance.effectiveSettings(settings)
      ..gameRoot = instance.root;
    snapshot.verifyDownloads = true;
    final network = OfficialNetwork(snapshot);
    InstallTask? task;
    try {
      final manifest = await network.json(versionManifestUrl, token: token);
      final raw = (manifest['versions'] as List)
          .cast<Json>()
          .where((v) => v['id'] == instance.version)
          .firstOrNull;
      if (raw == null) throw StateError('官方源中找不到 ${instance.version}。');
      final options = await instanceInstallOptions(instance, network, token);
      task = InstallTask(
        MinecraftVersion.fromJson(raw),
        '修复 ${instance.name}',
        snapshot,
        options: options,
      );
      tasks.insert(0, task);
      notifyListeners();
      final repaired = await MinecraftInstaller(
        platform,
        network,
        optifineBridge: options.optifine != null && options.loader == null
            ? (await rootBundle.load(
                'assets/java/FylOptiFineBridge.class',
              )).buffer.asUint8List()
            : null,
      ).install(task, token, _throttledNotify, existingInstance: instance);
      // Preserve presentation/settings edited while the download was in progress.
      final index = instances.indexWhere((i) => i.id == id);
      final current = instances[index];
      instances[index] = current.copyWith(
        managedJava: repaired.managedJava,
        installation: options.toJson(),
      );
      try {
        await _save();
      } catch (_) {
        instances[index] = current;
        rethrow;
      }
      task.status = TaskStatus.completed;
      task.stage = '修复完成';
      notice = '${instance.name} 的游戏文件已修复';
    } on Cancelled {
      if (task != null) {
        task.status = TaskStatus.cancelled;
        task.stage = '已取消';
      }
    } catch (e) {
      if (task != null) {
        task.status = TaskStatus.failed;
        task.stage = '修复失败';
        task.error = '$e';
      }
      rethrow;
    } finally {
      network.close();
      instanceOperation = null;
      _instanceToken = null;
      notifyListeners();
    }
  }

  Future<void> refreshVersions() async {
    if (loadingVersions) return;
    loadingVersions = true;
    notifyListeners();
    final cache = File(
      p.join(supportDirectory, 'cache', 'version_manifest.json'),
    );
    final network = OfficialNetwork(settings.copy());
    _manifestNetwork = network;
    try {
      final data = await network.json(versionManifestUrl);
      _applyManifest(data);
      manifestFromCache = false;
      await writeJson(cache, data);
    } catch (e) {
      if (await cache.exists()) {
        try {
          _applyManifest(jsonDecode(await cache.readAsString()) as Json);
          manifestFromCache = true;
        } catch (_) {
          errorMessage = '官方版本列表获取失败：$e';
        }
      } else {
        errorMessage = '无法连接官方版本源。请检查网络后点击刷新。\n$e';
      }
    } finally {
      network.close();
      _manifestNetwork = null;
      loadingVersions = false;
      notifyListeners();
    }
  }

  void _applyManifest(Json manifest) {
    final list = (manifest['versions'] as List<dynamic>)
        .map((v) => MinecraftVersion.fromJson(v as Json))
        .toList();
    versions
      ..clear()
      ..addAll(list);
    latestRelease = (manifest['latest'] as Json)['release'] as String;
  }

  Future<void> install(
    MinecraftVersion version, {
    String? name,
    InstallOptions options = const InstallOptions(),
  }) async {
    if (installing) {
      errorMessage = '请等待当前下载完成，或先取消当前任务。';
      notifyListeners();
      return;
    }
    final settingsError = settings.validate();
    if (settingsError != null) {
      errorMessage = settingsError;
      notifyListeners();
      return;
    }
    if (options.validationError != null) {
      errorMessage = options.validationError;
      notifyListeners();
      return;
    }
    try {
      assertGameDirectoryAvailable(
        settings.isolateVersions ? null : settings.gameRoot,
      );
    } catch (e) {
      errorMessage = '$e';
      notifyListeners();
      return;
    }
    final task = InstallTask(
      version,
      name?.trim().isNotEmpty == true ? name!.trim() : version.id,
      settings.copy(),
      options: options,
    );
    tasks.insert(0, task);
    final token = CancellationToken();
    _installToken = token;
    final network = OfficialNetwork(task.settings);
    notifyListeners();
    try {
      final instance = await MinecraftInstaller(
        platform,
        network,
        optifineBridge:
            task.options.optifine != null && task.options.loader == null
            ? (await rootBundle.load(
                'assets/java/FylOptiFineBridge.class',
              )).buffer.asUint8List()
            : null,
      ).install(task, token, _throttledNotify);
      instances.insert(0, instance);
      selectedId = instance.id;
      try {
        await _save();
      } catch (_) {
        instances.remove(instance);
        rethrow;
      }
      task.status = TaskStatus.completed;
      task.stage = '安装完成';
      task.completedFiles = task.totalFiles;
      notice = '${version.id} 安装完成，可以开始游戏了';
    } on Cancelled {
      task.status = TaskStatus.cancelled;
      task.stage = '已取消';
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = '$e';
      task.stage = '安装失败';
    } finally {
      network.close();
      _installToken = null;
      notifyListeners();
    }
  }

  void cancelInstall() {
    _installToken?.cancel();
    _instanceToken?.cancel();
    notice = '已请求取消任务';
    notifyListeners();
  }

  Future<void> stopActiveTasks() async {
    cancelInstall();
    for (final task in content.tasks) {
      if (task.state == ContentTaskState.running ||
          task.state == ContentTaskState.waiting) {
        content.cancel(task);
      }
    }
    if (!installing) return;
    final idle = Completer<void>();
    void changed() {
      if (!installing && !idle.isCompleted) idle.complete();
    }

    addListener(changed);
    try {
      changed();
      await idle.future;
    } finally {
      removeListener(changed);
    }
  }

  Future<void> launch() async {
    final instance = selectedInstance;
    if (instance == null || running || installing) return;
    preparingLaunch = true;
    lastExitCode = null;
    notice = null;
    errorMessage = null;
    logs.clear();
    notifyListeners();
    IOSink? log;
    try {
      final snapshot = instance.effectiveSettings(settings);
      final session = await prepareSession();
      final command = await MinecraftRunner(
        platform,
      ).prepare(instance, snapshot, session: session);
      if (snapshot.preLaunchCommand.trim().isNotEmpty) {
        final hook = await runPreLaunchCommand(
          snapshot.preLaunchCommand,
          command.workingDirectory,
          platform,
        );
        final code = hook.exitCode;
        final text = '${hook.stdout}\n${hook.stderr}'.trim();
        if (text.isNotEmpty) {
          logs.add(
            '[启动前命令] ${text.replaceAll(session.accessToken.isEmpty ? '\u0000' : session.accessToken, '[已隐藏登录凭据]')}',
          );
        }
        if (code != 0) throw StateError('启动前命令失败，退出码 $code。');
      }
      await _save();
      final logFile = File(
        p.join(
          instance.launcherDirectory,
          'logs',
          '${DateTime.now().millisecondsSinceEpoch}.log',
        ),
      );
      await logFile.parent.create(recursive: true);
      lastLogPath = logFile.path;
      log = logFile.openWrite();
      final process = await Process.start(
        command.executable,
        command.arguments,
        workingDirectory: command.workingDirectory,
        runInShell: false,
      );
      gameProcess = process;
      runningInstanceId = instance.id;
      preparingLaunch = false;
      notice = '游戏已启动';
      notifyListeners();
      final stdoutFormatter = GameLogFormatter();
      final stderrFormatter = GameLogFormatter();
      void line(String value, GameLogFormatter formatter) {
        if (session.online && session.accessToken.isNotEmpty) {
          value = value.replaceAll(session.accessToken, '[已隐藏登录凭据]');
        }
        log?.writeln(value);
        final formatted = formatter.format(value);
        if (formatted == null || formatted.isEmpty) return;
        logs.add(formatted);
        if (logs.length > 600) logs.removeRange(0, logs.length - 600);
        _throttledNotify();
      }

      line(
        '[Launcher] ${instance.version} / ${session.online ? '正版' : '离线'}用户 ${session.username}',
        stdoutFormatter,
      );
      final output = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((value) => line(value, stdoutFormatter));
      final errors = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((value) => line(value, stderrFormatter));
      unawaited(() async {
        try {
          final code = await process.exitCode;
          await Future.wait([output, errors]);
          lastExitCode = code;
          notice = code == 0 ? '游戏已正常退出' : '游戏退出，退出码 $code。可查看运行日志。';
        } catch (e) {
          errorMessage = '读取游戏日志失败：$e';
        } finally {
          await log?.close();
          log = null;
          gameProcess = null;
          runningInstanceId = null;
          notifyListeners();
        }
      }());
    } catch (e) {
      await log?.close();
      preparingLaunch = false;
      errorMessage = '$e';
      notifyListeners();
    }
  }

  Future<void> openDirectory(String path) async {
    try {
      await Directory(path).create(recursive: true);
      final process = await Process.run(
        platform.os == 'windows'
            ? 'explorer.exe'
            : platform.os == 'osx'
            ? 'open'
            : 'xdg-open',
        [p.normalize(path)],
      );
      // Explorer sometimes returns 1 even when the window opens.
      if (platform.os != 'windows' && process.exitCode != 0) {
        throw StateError('${process.stderr}');
      }
    } catch (e) {
      errorMessage = '打开文件夹失败：$e';
      notifyListeners();
    }
  }

  void dismissMessage() {
    errorMessage = null;
    notice = null;
    notifyListeners();
  }

  Future<void> flush() async {
    _usernameTimer?.cancel();
    await _save();
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    _usernameTimer?.cancel();
    _installToken?.cancel();
    _instanceToken?.cancel();
    _manifestNetwork?.close();
    content.dispose();
    super.dispose();
  }
}
