import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'minecraft.dart';
import 'game_log.dart';
import 'version_logs.dart';
import 'crash_report.dart';
import 'models.dart';
import 'network.dart';
import 'accounts.dart';
import 'account_store.dart';
import 'microsoft_auth.dart';
import 'install_options.dart';
import 'install_worker.dart';
import 'content_installer.dart';
import 'community_models.dart';
import 'instance_tools.dart';
import 'local_mods.dart';
import 'mod_updates.dart';
import 'community_catalog.dart';
import 'pack_import.dart' show ensurePackParents;
import 'game_window.dart';
import 'game_process_priority_session.dart';
import 'launch_progress.dart';
import 'launch_worker.dart';
import 'launch_tips.dart';
import 'system_memory.dart';
import 'data_directory.dart';
import 'pack_updates.dart';
import 'prepared_pack_updates.dart';
import 'pack_origin.dart';
import 'launcher_updates.dart';
import 'multiplayer.dart';
import 'build_info.dart';

class RunningGame {
  bool finished = false;
  final Process process;
  final String instanceId;
  final String gameDirectory;
  final String logPath;
  RunningGame({
    required this.process,
    required GameInstance instance,
    required this.logPath,
  }) : instanceId = instance.id,
       gameDirectory = instance.gameDirectory;
}

class LauncherController extends ChangeNotifier {
  late final multiplayer = MultiplayerController(
    supportDirectory: supportDirectory,
  );
  final String supportDirectory;
  final HostPlatform platform;
  final AccountTokenStore tokenStore;
  final MicrosoftAuth Function() authFactory;
  final SecureAccountTokenStore appSecrets;
  final ContentCatalogFactory? _communityCatalogFactory;
  final LaunchTips launchTips;
  final MemoryProbe memoryProbe;
  final DataDirectoryManager? dataDirectories;
  final Future<void> Function(String directory, bool migrate)?
  onDataDirectoryChange;
  Future<String?>? launchTip;
  ContentCatalogFactory get communityCatalogFactory =>
      _communityCatalogFactory ?? CommunityCatalog.new;
  late final launcherUpdater = LauncherUpdater(
    supportDirectory: supportDirectory,
    platform: platform,
    settings: () => settings,
    onChanged: _throttledNotify,
    explicitDataDirectory: dataDirectories?.directoryOverride,
  );
  static const _curseforgeKey = 'settings.curseforge-api-key';
  late final content = ContentInstaller(
    platform: platform,
    supportDirectory: supportDirectory,
    settings: () => settings.copy(),
    catalogFactory: communityCatalogFactory,
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
    onPreparedPackUpdate: (task) async {
      await validatePreparedPackUpdate(task, instances, supportDirectory);
      await _save();
    },
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
  final versionLogs = <String, VersionLog>{};
  final gameFailures = <GameFailure>[];
  final _logWrites = <String, Future<void>>{};
  String? selectedId;
  String? errorMessage;
  String? notice;
  String? latestRelease;
  String? latestSnapshot;
  bool loadingVersions = false;
  bool manifestFromCache = false;
  bool preparingLaunch = false;
  LaunchProgress? launchProgress;
  String? launchingInstanceName;
  int get launchSequence => _launchSequence;
  GameWindowWaiter? _windowWaiter;
  String? instanceOperation;
  String? repairingInstanceId;
  InstallTask? repairTask;
  CancellationToken? _instanceToken;
  final runningGames = <RunningGame>[];
  int _launchSequence = 0;
  RunningGame? _logGame;
  Process? get gameProcess => runningGames.lastOrNull?.process;
  bool get hasLiveLog => _logGame != null && runningGames.contains(_logGame);
  bool isInstanceRunning(String id) =>
      runningGames.any((game) => game.instanceId == id);
  bool isGameDirectoryInUse(String directory) =>
      runningGames.any((game) => p.equals(game.gameDirectory, directory));
  String? lastLogPath;
  int? lastExitCode;
  CancellationToken? _installToken;
  OfficialNetwork? _manifestNetwork;
  Timer? _notifyTimer;
  Timer? _usernameTimer;
  Future<void> _saveTail = Future.value();
  bool _disposed = false;
  bool _packRecoveryRequired = false;

  LauncherController({
    required this.supportDirectory,
    required this.platform,
    AccountTokenStore? tokenStore,
    MicrosoftAuth Function()? authFactory,
    SecureAccountTokenStore? appSecrets,
    ContentCatalogFactory? communityCatalogFactory,
    LaunchTips? launchTips,
    this.memoryProbe = readSystemMemory,
    this.dataDirectories,
    this.onDataDirectoryChange,
  }) : launchTips = launchTips ?? LaunchTips(),
       _communityCatalogFactory = communityCatalogFactory,
       appSecrets =
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
      _packRecoveryRequired ||
      launcherUpdater.busy ||
      instanceOperation != null ||
      tasks.any((t) => t.status == TaskStatus.running) ||
      content.tasks.any((t) => t.state == ContentTaskState.running);
  bool get running => preparingLaunch || runningGames.isNotEmpty;
  String get activityText {
    if (preparingLaunch) return launchProgress?.phase.label ?? '正在准备启动';
    if (instanceOperation != null) return '正在$instanceOperation';
    if (tasks.any((t) => t.status == TaskStatus.running)) return '正在安装游戏';
    if (content.tasks.any((t) => t.state == ContentTaskState.running)) {
      return '正在下载社区资源';
    }
    return '准备就绪';
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
    var saveAfterLoad = false;
    var preparedUpdates = <dynamic>[];
    await Directory(supportDirectory).create(recursive: true);
    if (launcherMultiplayerEnabled) await multiplayer.loadSettings();
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
        final savedDirectory = data['dataDirectory'];
        if (savedDirectory is String &&
            !p.equals(savedDirectory, supportDirectory)) {
          rebaseDataPaths(data, savedDirectory, supportDirectory);
        }
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
        preparedUpdates = data['preparedPackUpdates'] as List<dynamic>? ?? [];
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
          saveAfterLoad = true;
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
    try {
      notice = await recoverPackUpdate(supportDirectory, instances) ?? notice;
    } catch (error) {
      // Do not allow launching a version with an unresolved directory swap.
      instanceOperation = '恢复整合包升级';
      _packRecoveryRequired = true;
      errorMessage = '无法恢复整合包升级，请保留数据并重新启动：$error';
    }
    for (final raw in preparedUpdates) {
      try {
        final task = preparedPackUpdateFromJson(raw as Json);
        try {
          await validatePreparedPackUpdate(task, instances, supportDirectory);
        } catch (error) {
          // Keep failed preparations visible and discardable, even when their
          // cached archive is missing. Never move an untrusted staging path.
          try {
            validatePreparedPackUpdateLocation(
              task,
              instances,
              supportDirectory,
            );
          } catch (_) {
            task.preparedInstance = null;
            saveAfterLoad = true;
          }
          task.state = ContentTaskState.failed;
          task.stage = '安装失败';
          task.canRetry = false;
          task.error = error.toString();
        }
        content.tasks.add(task);
      } catch (error) {
        errorMessage = '无法恢复整合包升级，请保留数据并重新启动：$error';
      }
    }
    if (saveAfterLoad) await _save();
    final updateResult = File(
      p.join(supportDirectory, 'launcher-update-result.json'),
    );
    if (await updateResult.exists()) {
      try {
        final result = jsonDecode(await updateResult.readAsString()) as Json;
        if (result['error'] is String) {
          launcherUpdater.error = result['error'] as String;
          notice = '启动器更新未完成：${result['error']}';
        }
        await updateResult.delete();
      } catch (_) {
        /* A failed update notice must not prevent startup. */
      }
    }
    notifyListeners();
  }

  Future<void> _save({ContentTask? completedPackUpdate}) {
    final data = <String, dynamic>{
      'schemaVersion': 2,
      'dataDirectory': supportDirectory,
      'settings': settings.toJson(),
      'instances': instances.map((i) => i.toJson()).toList(),
      'preparedPackUpdates': [
        for (final task in content.tasks)
          if (task.preparedInstance != null &&
              !identical(task, completedPackUpdate))
            preparedPackUpdateJson(task),
      ],
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

  Future<void> changeDataDirectory(
    String directory, {
    required bool migrate,
  }) async {
    if (launcherMultiplayerEnabled && multiplayer.active) {
      throw StateError('请先断开联机，再切换数据目录');
    }
    if (installing || running) throw StateError('请先结束下载任务并关闭正在运行的游戏，再切换数据目录。');
    final change = onDataDirectoryChange;
    if (change == null) throw StateError('当前运行环境不支持切换数据目录。');
    await flush();
    await change(directory, migrate);
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
        final versionLog = versionLogs[value.id];
        if (versionLog != null) versionLog.path = relocated(versionLog.path);
        for (final failure in gameFailures.where(
          (failure) => failure.instanceId == value.id,
        )) {
          failure.logPath = relocated(failure.logPath);
        }
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

  Future<Json> linkPackProject(
    String instanceId,
    ContentProject project, {
    ContentVersion? installed,
  }) async {
    final instance = editableInstance(instanceId);
    instanceOperation = '关联整合包来源';
    notifyListeners();
    try {
      final target = p.join(instance.launcherDirectory, 'modpack.json');
      await ensurePackParents(instance.root, target);
      final updated = linkedPackRecord(
        await readPackRecord(instance),
        project,
        installed: installed,
      );
      await writeJson(File(target), updated);
      return updated;
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<GameInstance> applyPackUpdate(
    PackUpdatePreview preview,
    Set<String> useIncoming,
    ContentTask task, {
    required bool keepOriginal,
    String? copyName,
  }) async {
    final original = editableInstance(preview.original.id);
    if (!task.canRetry) throw StateError('此升级预览已使用，请关闭后重新准备。');
    if (keepOriginal) {
      final name = copyName?.trim() ?? preview.staged.name;
      final invalid = validateVersionName(name);
      if (invalid != null) throw ArgumentError(invalid);
      if (instances.any(
        (instance) => instance.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw StateError('版本名称已存在，请使用其他名称。');
      }
    }
    if (jsonEncode(original.toJson()) !=
        jsonEncode(preview.original.toJson())) {
      throw StateError('版本设置已变化，请重新预览升级。');
    }
    if (!original.isolated && !keepOriginal) {
      throw StateError('未隔离的整合包需要升级到独立副本。');
    }
    final staged = preview.staged;
    if (staged.root != original.root ||
        !staged.isolated ||
        !staged.name.startsWith('FYL-update-')) {
      throw const FormatException('整合包升级暂存目录无效。');
    }
    task.canRetry = false;
    task.state = ContentTaskState.running;
    task.stage = '应用整合包升级';
    instanceOperation = '升级整合包';
    _instanceToken = task.token;
    notifyListeners();
    final backupRoot = safeJoin(
      p.join(original.root, '.fyl', 'pack-backups'),
      task.id,
    );
    final backup = p.join(backupRoot, 'version');
    var archived = false, promoted = false, saved = false;
    GameInstance? updated;
    final index = instances.indexWhere(
      (instance) => instance.id == original.id,
    );
    try {
      await mergePackUpdate(preview, useIncoming, task.token);
      final personal = <String, dynamic>{
        'description': original.description,
        'category': original.category,
        'favorite': original.favorite,
        'javaMode': original.javaMode.name,
        'javaPath': original.javaPath,
        'launchSettings': original.launchSettings.toJson(),
      };
      if (original.icon != 'auto') {
        personal['icon'] = original.icon;
        if (p.isWithin(original.versionDirectory, original.icon)) {
          final relative = p.relative(
            original.icon,
            from: original.versionDirectory,
          );
          final target = safeJoin(staged.versionDirectory, relative);
          await ensurePackParents(staged.root, target);
          if (await FileSystemEntity.type(original.icon, followLinks: false) !=
              FileSystemEntityType.file) {
            throw StateError('自定义图标无法读取。');
          }
          await File(target).parent.create(recursive: true);
          await File(original.icon).copy(target);
          if (keepOriginal) personal['icon'] = target;
        }
      }
      if (keepOriginal) {
        final name = copyName?.trim() ?? staged.name;
        final invalid = validateVersionName(name);
        if (invalid != null) throw ArgumentError(invalid);
        if (instances.any(
          (instance) => instance.name.toLowerCase() == name.toLowerCase(),
        )) {
          throw StateError('版本名称已存在，请使用其他名称。');
        }
        updated = GameInstance.fromJson({
          ...staged.toJson(),
          ...personal,
          'name': name,
        });
        if (p.isWithin(staged.versionDirectory, updated.icon)) {
          updated = updated.copyWith(
            icon: p.join(
              updated.versionDirectory,
              p.relative(updated.icon, from: staged.versionDirectory),
            ),
          );
        }
        await renameVersionDirectory(staged, updated);
        instances.insert(0, updated);
        final selected = selectedId;
        selectedId = updated.id;
        try {
          await _save(completedPackUpdate: task);
        } catch (_) {
          instances.remove(updated);
          selectedId = selected;
          await renameVersionDirectory(updated, staged);
          rethrow;
        }
        saved = true;
      } else {
        updated = GameInstance.fromJson({
          ...staged.toJson(),
          ...personal,
          'id': original.id,
          'name': original.name,
          'createdAt': original.createdAt.toIso8601String(),
          'installation': {...staged.installation, 'packBackup': backupRoot},
        });
        await ensurePackParents(original.root, backup);
        await Directory(backupRoot).create(recursive: true);
        await writeJson(
          File(p.join(backupRoot, 'instance.json')),
          original.toJson(),
        );
        await writePackUpdateJournal(supportDirectory, {
          'original': original.toJson(),
          'updated': updated.toJson(),
          'backup': backup,
        });
        task.token.check();
        await Directory(original.versionDirectory).rename(backup);
        archived = true;
        await renameVersionDirectory(staged, updated);
        promoted = true;
        instances[index] = updated;
        try {
          await _save(completedPackUpdate: task);
        } catch (_) {
          instances[index] = original;
          rethrow;
        }
        saved = true;
        try {
          await File(
            p.join(supportDirectory, 'pack-update-journal.json'),
          ).delete();
        } catch (_) {
          /* Startup recovery verifies the committed installation. */
        }
      }
      task.preparedInstance = null;
      task.destination = updated.gameDirectory;
      task.stage = '整合包升级完成';
      task.state = ContentTaskState.completed;
      task.error = null;
      notice = '${original.name} 升级完成';
      return updated;
    } catch (error) {
      if (!saved && archived) {
        _packRecoveryRequired = true;
        if (promoted) {
          await renameVersionDirectory(updated!, staged);
        }
        await Directory(backup).rename(original.versionDirectory);
        final journal = File(
          p.join(supportDirectory, 'pack-update-journal.json'),
        );
        if (await journal.exists()) await journal.delete();
        _packRecoveryRequired = false;
      }
      task.state = error is Cancelled
          ? ContentTaskState.cancelled
          : ContentTaskState.failed;
      task.error = error.toString();
      rethrow;
    } finally {
      instanceOperation = null;
      _instanceToken = null;
      notifyListeners();
    }
  }

  Future<void> discardPackUpdate(ContentTask task) async {
    final staged = task.preparedInstance;
    if (staged == null || task.state == ContentTaskState.running) return;
    if (instanceOperation != null) throw StateError('请等待当前任务完成。');
    if (!staged.name.startsWith('FYL-update-') ||
        instances.any(
          (instance) =>
              instance.id == staged.id ||
              p.equals(instance.versionDirectory, staged.versionDirectory),
        )) {
      return;
    }
    final retained = safeJoin(
      p.join(staged.root, '.fyl-trash'),
      'unused-update-${task.id}',
    );
    instanceOperation = '升级整合包';
    var moved = false;
    try {
      await ensurePackParents(staged.root, staged.versionDirectory);
      await ensurePackParents(staged.root, retained);
      if (await Directory(staged.versionDirectory).exists()) {
        await Directory(staged.versionDirectory).rename(retained);
        moved = true;
      }
      task.preparedInstance = null;
      try {
        await _save();
      } catch (_) {
        task.preparedInstance = staged;
        if (moved) await Directory(retained).rename(staged.versionDirectory);
        rethrow;
      }
      task.destination = retained;
      task.state = ContentTaskState.cancelled;
      task.canRetry = false;
      task.stage = '已取消';
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<void> restorePackBackup(String id) async {
    final original = editableInstance(id);
    final path = original.installation['packBackup'] as String?;
    if (path == null ||
        !p.isWithin(p.join(original.root, '.fyl', 'pack-backups'), path)) {
      throw StateError('没有可还原的整合包升级备份。');
    }
    final backup = p.join(path, 'version');
    final retained = '$path.reverted';
    await ensurePackParents(original.root, retained);
    if (!await Directory(backup).exists() ||
        await Directory(retained).exists()) {
      throw StateError('整合包备份目录无法使用。');
    }
    instanceOperation = '还原整合包';
    notifyListeners();
    final index = instances.indexWhere((instance) => instance.id == id);
    var moved = false, restored = false, committed = false;
    String? prepared;
    try {
      final preparation = await preparePackBackupRestore(original, path);
      final previous = preparation.$1;
      prepared = preparation.$2;
      await writePackUpdateJournal(supportDirectory, {
        'original': original.toJson(),
        'updated': previous.toJson(),
        'backup': retained,
      });
      await Directory(original.versionDirectory).rename(retained);
      moved = true;
      await Directory(prepared).rename(original.versionDirectory);
      restored = true;
      instances[index] = previous;
      try {
        await _save();
      } catch (_) {
        instances[index] = original;
        rethrow;
      }
      committed = true;
      try {
        await File(
          p.join(original.versionDirectory, '.fyl-restore-owner'),
        ).delete();
        await File(
          p.join(supportDirectory, 'pack-update-journal.json'),
        ).delete();
      } catch (_) {
        /* The committed record is recognized on next startup. */
      }
      notice = '已还原升级前的整合包，升级后的文件已保留。';
    } catch (_) {
      if (!committed) {
        _packRecoveryRequired = true;
        if (restored) {
          await Directory(original.versionDirectory).rename(prepared!);
        }
        if (moved) await Directory(retained).rename(original.versionDirectory);
        _packRecoveryRequired = false;
      }
      rethrow;
    } finally {
      try {
        if (prepared != null && !_packRecoveryRequired) {
          await removePreparedPackRestore(original, prepared);
        }
      } finally {
        instanceOperation = null;
        notifyListeners();
      }
    }
  }

  GameInstance editableInstance(String id) {
    final instance = instances.where((i) => i.id == id).firstOrNull;
    if (instance == null) throw StateError('此版本已不存在。');
    if (installing) throw StateError('请等待当前任务完成。');
    if (preparingLaunch || isGameDirectoryInUse(instance.gameDirectory)) {
      throw StateError('请先关闭使用此目录的游戏。');
    }
    return instance;
  }

  void assertGameDirectoryAvailable(String? directory) {
    if (preparingLaunch ||
        directory != null && isGameDirectoryInUse(directory)) {
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

  Future<ModUpdateCheck> checkModUpdates(
    String id,
    List<LocalMod> mods,
    CancellationToken token, {
    ModUpdateProgress? onProgress,
  }) async {
    final instance = instances.where((i) => i.id == id).firstOrNull;
    if (instance == null) throw StateError('版本已移除。');
    final catalog = communityCatalogFactory(settings.copy());
    try {
      return await ModUpdater(
        catalog,
        supportDirectory,
      ).check(instance, mods, token, onProgress: onProgress);
    } finally {
      catalog.close();
    }
  }

  Future<void> installModUpdates(
    String id,
    List<ModUpdate> updates,
    ModUpdateCheck check, {
    ModUpdateProgress? onProgress,
  }) async {
    if (updates.isEmpty) return;
    final instance = editableInstance(id);
    instanceOperation = '更新 Mod';
    final token = _instanceToken = CancellationToken();
    final catalog = communityCatalogFactory(settings.copy());
    notifyListeners();
    try {
      await ModUpdater(
        catalog,
        supportDirectory,
      ).apply(instance, updates, check, token, onProgress: onProgress);
      notice = '${updates.length} 个 Mod 已更新';
    } finally {
      catalog.close();
      instanceOperation = null;
      _instanceToken = null;
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
    repairingInstanceId = id;
    repairTask = null;
    errorMessage = null;
    notice = null;
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
      repairTask = task;
      tasks.insert(0, task);
      notifyListeners();
      final repaired = await runInstallerWorker(
        platform,
        task,
        instance,
        token,
        optifineBridge: options.optifine != null && options.loader == null
            ? (await rootBundle.load(
                'assets/java/FylOptiFineBridge.class',
              )).buffer.asUint8List()
            : null,
        onProgress: (progress) {
          progress.apply(task!);
          _throttledNotify();
        },
      );
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
      notice = '已取消修复';
      if (task != null) {
        task.status = TaskStatus.cancelled;
        task.stage = '已取消';
      }
    } catch (e) {
      final message = e is StateError ? e.message.toString() : '$e';
      errorMessage = '修复失败：$message';
      if (task != null) {
        task.status = TaskStatus.failed;
        task.stage = '修复失败';
        task.error = message;
      }
      rethrow;
    } finally {
      network.close();
      instanceOperation = null;
      repairingInstanceId = null;
      repairTask = null;
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
    latestSnapshot = (manifest['latest'] as Json)['snapshot'] as String?;
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
    notifyListeners();
    try {
      final instance = await runInstallerWorker(
        platform,
        task,
        null,
        token,
        optifineBridge:
            task.options.optifine != null && task.options.loader == null
            ? (await rootBundle.load(
                'assets/java/FylOptiFineBridge.class',
              )).buffer.asUint8List()
            : null,
        onProgress: (progress) {
          progress.apply(task);
          _throttledNotify();
        },
      );
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

  bool dismissInstallTask(InstallTask task) {
    if (task.status == TaskStatus.running || !tasks.remove(task)) return false;
    if (identical(repairTask, task)) repairTask = null;
    notifyListeners();
    return true;
  }

  bool dismissContentTask(ContentTask task) {
    if (!content.dismiss(task)) return false;
    notifyListeners();
    return true;
  }

  Future<void> prepareLauncherUpdate() async {
    if (launcherMultiplayerEnabled && multiplayer.active) {
      throw StateError('请先断开联机，再更新启动器');
    }
    if (installing || running) throw StateError('请先结束下载任务并关闭正在运行的游戏，再更新启动器。');
    instanceOperation = '更新启动器';
    notifyListeners();
    try {
      await flush();
      await launcherUpdater.startHelper();
    } finally {
      instanceOperation = null;
      notifyListeners();
    }
  }

  Future<void> stopActiveTasks() async {
    launcherUpdater.cancel();
    if (_packRecoveryRequired && _instanceToken == null) return;
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

  Future<LaunchCommand> prepareLaunch(
    GameInstance instance,
    LauncherSettings snapshot,
    GameSession session,
  ) => prepareGameInBackground(
    platform,
    instance,
    snapshot,
    session,
    _launchProgress,
  );

  void _launchProgress(LaunchProgress progress) {
    if (_disposed || !preparingLaunch) return;
    final changed = launchProgress?.phase != progress.phase;
    launchProgress = progress;
    if (changed) {
      notifyListeners();
    } else {
      _throttledNotify();
    }
  }

  Future<bool> waitForGameWindow(RunningGame game, GameWindowWaiter waiter) =>
      waiter.wait(game.process);

  void stopWaitingForGameWindow() {
    if (launchProgress?.phase == LaunchPhase.window) _windowWaiter?.stop();
  }

  Future<Process> startGameProcess(LaunchCommand command) => Process.start(
    command.executable,
    command.arguments,
    workingDirectory: command.workingDirectory,
    runInShell: false,
  );

  Future<VersionLog?> loadVersionLog(String instanceId) async {
    if (versionLogs.containsKey(instanceId)) return versionLogs[instanceId];
    final instance = instances
        .where((item) => item.id == instanceId)
        .firstOrNull;
    if (instance == null) return null;
    final log = await readLatestLog(instance);
    if (log == null) return null;
    log.lines.addAll(await loadLogLines(log.path));
    final current = versionLogs.putIfAbsent(instanceId, () => log);
    await _pruneLogs(instance);
    return current;
  }

  bool isVersionLogLive(VersionLog log) =>
      log.endedAt == null &&
      runningGames.any((game) => game.logPath == log.path);

  Future<void> _pruneLogs(GameInstance instance) => pruneVersionLogs(
    instance,
    settings.retainedGameLogs,
    runningGames
        .where((game) => !game.finished)
        .map((game) => game.logPath)
        .followedBy(gameFailures.map((failure) => failure.logPath))
        .toSet(),
  );

  Future<void> dismissGameFailure(GameFailure failure) async {
    gameFailures.remove(failure);
    notifyListeners();
    final instance = instances
        .where((item) => item.id == failure.instanceId)
        .firstOrNull;
    if (instance != null) await _pruneLogs(instance);
  }

  Future<void> _saveLogMetadata(GameInstance instance, VersionLog log) {
    final previous = _logWrites[instance.id] ?? Future<void>.value();
    final next = previous.catchError((_) {}).then((_) async {
      if (identical(versionLogs[instance.id], log)) {
        await saveLatestLog(instance, log);
      }
    });
    _logWrites[instance.id] = next;
    return next;
  }

  Future<bool> launch() async {
    final instance = selectedInstance;
    if (instance == null || preparingLaunch || installing || _disposed) {
      return false;
    }
    final sequence = ++_launchSequence;
    preparingLaunch = true;
    launchingInstanceName = instance.name;
    launchProgress = const LaunchProgress(LaunchPhase.account);
    launchTip = launchTips.choose().catchError((_) => null);
    _logGame = null;
    lastExitCode = null;
    lastLogPath = null;
    notice = null;
    errorMessage = null;
    logs.clear();
    notifyListeners();
    IOSink? log;
    GameProcessPrioritySession? priority;
    try {
      final snapshot = instance.effectiveSettings(settings);
      final session = await prepareSession();
      final command = await prepareLaunch(instance, snapshot, session);
      if (command.memory != null) logs.add(command.memory!.logMessage);
      if (_disposed) throw const Cancelled();
      if (snapshot.preLaunchCommand.trim().isNotEmpty) {
        _launchProgress(const LaunchProgress(LaunchPhase.hook));
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
          '${DateTime.now().millisecondsSinceEpoch}-$sequence.log',
        ),
      );
      await ensureVersionLogDirectory(instance);
      lastLogPath = logFile.path;
      log = logFile.openWrite();
      final versionLog = VersionLog(
        logFile.path,
        DateTime.now(),
        gameDirectory: instance.gameDirectory,
      );
      versionLog.lines.addAll(logs);
      for (final line in logs) {
        log.writeln(line);
      }
      if (_disposed) throw const Cancelled();
      _launchProgress(const LaunchProgress(LaunchPhase.process));
      final process = await startGameProcess(command);
      final game = RunningGame(
        process: process,
        instance: instance,
        logPath: logFile.path,
      );
      runningGames.add(game);
      versionLogs[instance.id] = versionLog;
      _logGame = game;
      final waiter = _windowWaiter = GameWindowWaiter();
      _launchProgress(const LaunchProgress(LaunchPhase.window));
      final stdoutFormatter = GameLogFormatter();
      final stderrFormatter = GameLogFormatter();
      void line(String value, GameLogFormatter formatter) {
        if (session.online && session.accessToken.isNotEmpty) {
          value = value.replaceAll(session.accessToken, '[已隐藏登录凭据]');
        }
        log?.writeln(value);
        final formatted = formatter.format(value);
        if (formatted == null || formatted.isEmpty) return;
        waiter.observe(formatted);
        versionLog.append(formatted);
        if (_launchSequence == sequence) {
          logs.add(formatted);
          if (logs.length > 600) logs.removeRange(0, logs.length - 600);
        }
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
      if (platform.os == 'windows') {
        try {
          priority = GameProcessPrioritySession(
            pid: process.pid,
            priority: snapshot.gameProcessPriority,
            onLog: (value) => line(value, stdoutFormatter),
          );
          await priority.start();
        } catch (error) {
          line('[Launcher] 无法设置游戏进程优先级：$error', stdoutFormatter);
        }
      }
      var processExited = false;
      unawaited(() async {
        int? exitCode;
        try {
          final code = await process.exitCode;
          processExited = true;
          await priority?.finish();
          exitCode = code;
          versionLog.exitCode = code;
          versionLog.endedAt = DateTime.now();
          await Future.wait([output, errors]);
          if (_launchSequence == sequence) {
            lastExitCode = code;
            notice = code == 0 ? '游戏已正常退出' : null;
          }
        } catch (e) {
          if (_launchSequence == sequence) errorMessage = '读取游戏日志失败：$e';
        } finally {
          try {
            await log?.close();
          } catch (error) {
            errorMessage = '写入游戏日志失败：$error';
          }
          log = null;
          if (exitCode != null && exitCode != 0 && !_disposed) {
            final secrets = [session.accessToken, snapshot.curseforgeApiKey];
            try {
              int? pid;
              try {
                pid = process.pid;
              } catch (_) {
                // Some embedded process adapters do not expose a native PID.
              }
              final latest = !versionLogs.values.any(
                (other) =>
                    other.gameDirectory != null &&
                    p.equals(other.gameDirectory!, game.gameDirectory) &&
                    other.startedAt.isAfter(versionLog.startedAt),
              );
              final shared = runningGames.any(
                (other) =>
                    !identical(other, game) &&
                    p.equals(other.gameDirectory, game.gameDirectory),
              );
              gameFailures.add(
                await captureGameFailure(
                  instance: instance,
                  log: versionLog,
                  platform: platform,
                  java: command.executable,
                  minMemory: command.memory?.initialMiB ?? snapshot.minMemory,
                  maxMemory: command.memory?.maximumMiB ?? snapshot.maxMemory,
                  exitCode: exitCode,
                  pid: pid,
                  includeGameLogs: latest && !shared,
                  secrets: secrets,
                ),
              );
            } catch (failure) {
              gameFailures.add(
                GameFailure(
                  instanceId: instance.id,
                  instanceName: instance.name,
                  logPath: versionLog.path,
                  exitCode: exitCode,
                  secrets: secrets,
                  files: {
                    'report.txt': sanitizeDiagnosticText(
                      '版本名称: ${instance.name}\n退出码: $exitCode\n读取附加诊断信息失败: $failure',
                      secrets,
                    ),
                    'launcher.log': sanitizeDiagnosticText(
                      versionLog.lines.join('\n'),
                      secrets,
                    ),
                  },
                ),
              );
            }
          }
          game.finished = true;
          try {
            await _saveLogMetadata(instance, versionLog);
            await _pruneLogs(instance);
          } catch (error) {
            errorMessage = '保存版本日志失败：$error';
          }
          runningGames.remove(game);
          notifyListeners();
        }
      }());
      unawaited(() async {
        try {
          await _saveLogMetadata(instance, versionLog);
          await _pruneLogs(instance);
        } catch (error) {
          errorMessage = '保存版本日志失败：$error';
          notifyListeners();
        }
      }());
      bool ready;
      try {
        ready = await waitForGameWindow(game, waiter);
        await priority?.finish();
      } finally {
        waiter.stop();
        if (identical(_windowWaiter, waiter)) _windowWaiter = null;
      }
      if (_disposed) return false;
      preparingLaunch = false;
      launchProgress = null;
      launchingInstanceName = null;
      if (ready) {
        notice = '游戏窗口已打开';
      } else if (!processExited &&
          runningGames.contains(game) &&
          !game.finished) {
        notice = '已停止等待游戏窗口，游戏进程继续运行。';
      }
      notifyListeners();
      return ready;
    } catch (e) {
      _windowWaiter?.stop();
      _windowWaiter = null;
      preparingLaunch = false;
      launchProgress = null;
      launchingInstanceName = null;
      errorMessage = '$e';
      await priority?.finish();
      try {
        await log?.close();
      } catch (_) {
        // Preserve the launch failure while still restoring the ready state.
      }
      notifyListeners();
      return false;
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
    if (launcherMultiplayerEnabled) multiplayer.dispose();
    launcherUpdater.dispose();
    _disposed = true;
    _windowWaiter?.stop();
    _notifyTimer?.cancel();
    _usernameTimer?.cancel();
    _installToken?.cancel();
    _instanceToken?.cancel();
    _manifestNetwork?.close();
    content.dispose();
    super.dispose();
  }
}
