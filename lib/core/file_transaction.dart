import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'network.dart';

/// Publishes a set of files as one recoverable filesystem transaction.
///
/// Destinations and removals must be inside [root]. Files are copied to
/// temporary siblings first, then committed while any replaced/removed files
/// are kept as backups. Cancellation or an error during commit restores the
/// previous files. The progress callback reports committed changes. [finalize]
/// runs after the files commit but before their backups are discarded.
Future<void> publishFiles(
  String root,
  List<(String, String)> copies,
  CancellationToken token, {
  List<String> removals = const [],
  void Function(int, int)? onProgress,
  Future<void> Function()? finalize,
}) async {
  final normalizedRoot = p.normalize(p.absolute(root));
  final rootType = await FileSystemEntity.type(
    normalizedRoot,
    followLinks: false,
  );
  if (rootType == FileSystemEntityType.link ||
      rootType == FileSystemEntityType.file) {
    throw const FormatException('事务根目录必须是普通目录。');
  }

  final id =
      '${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(token)}';
  final changes = <_Change>[];
  final seen = <String>{};
  String keyFor(String path) =>
      Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path);

  String validateTarget(String path) {
    final absolute = p.normalize(p.absolute(path));
    if (p.equals(absolute, normalizedRoot) ||
        !p.isWithin(normalizedRoot, absolute)) {
      throw FormatException('事务目标超出根目录：$path');
    }
    final relative = p.relative(absolute, from: normalizedRoot);
    return safeJoin(normalizedRoot, relative);
  }

  for (final (sourcePath, targetPath) in copies) {
    final source = p.normalize(p.absolute(sourcePath));
    final target = validateTarget(targetPath);
    if (!seen.add(keyFor(target))) {
      throw FormatException('事务目标重复：$targetPath');
    }
    final sourceType = await FileSystemEntity.type(source, followLinks: false);
    if (sourceType != FileSystemEntityType.file) {
      throw FormatException('事务源必须是普通文件：$sourcePath');
    }
    changes.add(_Change(target, source: source));
  }
  for (final removalPath in removals) {
    final target = validateTarget(removalPath);
    if (!seen.add(keyFor(target))) {
      throw FormatException('事务目标重复：$removalPath');
    }
    changes.add(_Change(target));
  }

  try {
    for (var i = 0; i < changes.length; i++) {
      token.check();
      final change = changes[i];
      await _checkParents(normalizedRoot, p.dirname(change.target));
      final targetType = await FileSystemEntity.type(
        change.target,
        followLinks: false,
      );
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.file) {
        throw FormatException('事务目标不是普通文件：${change.target}');
      }
      if (change.source != null) {
        final parent = Directory(p.dirname(change.target));
        await parent.create(recursive: true);
        final temp = _sibling(change.target, 'stage', id, i);
        if (await FileSystemEntity.type(temp, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('事务临时文件已存在：$temp');
        }
        change.staged = temp;
        await File(change.source!).copy(temp);
      }
    }
  } catch (_) {
    await _removeStaged(changes);
    rethrow;
  }

  var committed = 0;
  try {
    token.check();
    for (var i = 0; i < changes.length; i++) {
      final change = changes[i];
      // Do not check again after the last operation: cancellation after the
      // commit is complete must not turn a successful publish into a rollback.
      token.check();
      final targetType = await FileSystemEntity.type(
        change.target,
        followLinks: false,
      );
      if (targetType == FileSystemEntityType.file) {
        final backup = _sibling(change.target, 'backup', id, i);
        if (await FileSystemEntity.type(backup, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('事务备份文件已存在：$backup');
        }
        await File(change.target).rename(backup);
        change.backup = backup;
      } else if (targetType != FileSystemEntityType.notFound) {
        throw FormatException('事务目标状态已改变：${change.target}');
      }
      if (change.staged != null) {
        await File(change.staged!).rename(change.target);
        change.staged = null;
        change.published = true;
      }
      committed++;
      onProgress?.call(committed, changes.length);
    }
    if (finalize != null) {
      token.check();
      await finalize();
    }
  } catch (_) {
    for (final change in changes.reversed) {
      try {
        if (change.published &&
            await FileSystemEntity.type(change.target, followLinks: false) ==
                FileSystemEntityType.file) {
          await File(change.target).delete();
        }
        final backup = change.backup;
        if (backup != null &&
            await FileSystemEntity.type(backup, followLinks: false) ==
                FileSystemEntityType.file) {
          await File(backup).rename(change.target);
          change.backup = null;
        }
      } catch (_) {
        // Leave any surviving backup in place rather than discard the original.
      }
    }
    rethrow;
  } finally {
    await _removeStaged(changes);
  }

  for (final change in changes) {
    final backup = change.backup;
    if (backup != null) {
      final type = await FileSystemEntity.type(backup, followLinks: false);
      if (type == FileSystemEntityType.file) {
        try {
          await File(backup).delete();
        } catch (_) {
          // Publishing succeeded; a leftover backup is safer than a false
          // failure after some other backups have already been removed.
        }
      }
      change.backup = null;
    }
  }
}

Future<void> _removeStaged(List<_Change> changes) async {
  for (final change in changes) {
    final staged = change.staged;
    if (staged == null) continue;
    try {
      final type = await FileSystemEntity.type(staged, followLinks: false);
      if (type == FileSystemEntityType.file) await File(staged).delete();
    } catch (_) {}
  }
}

Future<void> _checkParents(String root, String parentPath) async {
  final parent = p.normalize(p.absolute(parentPath));
  if (!p.equals(parent, root) && !p.isWithin(root, parent)) {
    throw FormatException('事务父目录超出根目录：$parentPath');
  }
  var current = root;
  final rootType = await FileSystemEntity.type(current, followLinks: false);
  if (rootType == FileSystemEntityType.link ||
      rootType == FileSystemEntityType.file) {
    throw FormatException('事务根目录不是普通目录：$root');
  }
  final relative = p.relative(parent, from: root);
  for (final part in p.split(relative)) {
    if (part == '.' || part.isEmpty) continue;
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.file) {
      throw FormatException('事务父路径包含链接或文件：$current');
    }
  }
}

String _sibling(String target, String kind, String id, int index) =>
    p.join(p.dirname(target), '.${p.basename(target)}.fyl-$kind-$id-$index');

class _Change {
  final String target;
  final String? source;
  String? staged;
  String? backup;
  bool published = false;
  _Change(this.target, {this.source});
}
