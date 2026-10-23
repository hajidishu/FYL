import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'community_catalog.dart';
import 'community_models.dart';
import 'mod_updates.dart' show fingerprintMod;
import 'models.dart';
import 'network.dart';
import 'pack_import.dart' show ensurePackParents;
import 'pack_updates.dart' show packFileHash;

bool hasOnlinePackOrigin(Json record) =>
    ContentSource.values.any((source) => source.name == record['source']) &&
    record['projectId'] is String &&
    (record['projectId'] as String).isNotEmpty &&
    !(record['projectId'] as String).startsWith('local-');

String? importedPackHash(Json record) {
  final explicit = record['importedArchiveSha256'];
  final project = record['projectId'];
  final candidate = explicit is String
      ? explicit
      : project is String && project.startsWith('local-')
      ? project.substring(6)
      : null;
  return candidate != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(candidate)
      ? candidate
      : null;
}

class PackOriginMatch {
  final ContentProject project;
  final ContentVersion version;
  const PackOriginMatch(this.project, this.version);
}

Future<String> _archiveHash(String path) =>
    Isolate.run(() => packFileHash(path));

/// Match the original archive, never a guessed name or the latest release.
Future<PackOriginMatch?> identifyImportedPack(
  Json record,
  String supportDirectory,
  CommunityCatalog catalog,
  CancellationToken token,
) async {
  final hash = importedPackHash(record);
  if (hash == null) return null;
  final archive = p.join(
    supportDirectory,
    'cache',
    'local-packs',
    hash,
    'pack.zip',
  );
  await ensurePackParents(supportDirectory, archive);
  if (await FileSystemEntity.type(archive, followLinks: false) !=
      FileSystemEntityType.file) {
    return null;
  }
  if (await _archiveHash(archive) != hash) return null;
  token.check();
  final fingerprint = await fingerprintMod(archive);
  token.check();
  var hadCandidate = false;
  Object? failure;
  Future<PackOriginMatch?> verify(ContentVersion version) async {
    hadCandidate = true;
    if (!version.files.any((file) => file.hashes['sha1'] == fingerprint.hash)) {
      return null;
    }
    try {
      final project = await catalog.project(
        version.source,
        version.projectId,
        ContentKind.modpack,
        token,
      );
      if (project.kind == ContentKind.modpack) {
        return PackOriginMatch(project, version);
      }
    } catch (error) {
      token.check();
      failure = error;
    }
    return null;
  }

  try {
    final versions = await catalog.versionsFromHashes([
      fingerprint.hash,
    ], token);
    final version = versions[fingerprint.hash];
    if (version != null) {
      final match = await verify(version);
      if (match != null) return match;
    }
  } catch (error) {
    token.check();
    failure = error;
  }
  if (catalog.settings.curseforgeApiKey.isNotEmpty) {
    try {
      for (final version in await catalog.fingerprintMatches([
        fingerprint.curse,
      ], token)) {
        final match = await verify(version);
        if (match != null) return match;
      }
    } catch (error) {
      token.check();
      failure = error;
    }
  }
  if (failure != null && !hadCandidate) throw failure!;
  return null;
}

class PackProjectReference {
  final ContentSource source;
  final String id;
  const PackProjectReference(this.source, this.id);
}

PackProjectReference parsePackProjectReference(
  ContentSource source,
  String input,
) {
  input = input.trim();
  if (input.isEmpty) throw const FormatException('请填写整合包项目链接或 ID。');
  final uri = Uri.tryParse(input);
  if (uri != null && uri.hasScheme) {
    if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
      throw const FormatException('请填写 Modrinth 或 CurseForge 的整合包项目链接。');
    }
    final parts = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    if (const {'modrinth.com', 'www.modrinth.com'}.contains(uri.host) &&
        parts.length >= 2 &&
        parts[0] == 'modpack') {
      source = ContentSource.modrinth;
      input = parts[1];
    } else if (const {
          'curseforge.com',
          'www.curseforge.com',
        }.contains(uri.host) &&
        parts.length >= 3 &&
        parts[0] == 'minecraft' &&
        parts[1] == 'modpacks') {
      source = ContentSource.curseforge;
      input = parts[2];
    } else {
      throw const FormatException('请填写 Modrinth 或 CurseForge 的整合包项目链接。');
    }
  }
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(input)) {
    throw const FormatException('整合包项目 ID 或链接无效。');
  }
  return PackProjectReference(source, input);
}

Future<ContentProject> resolvePackProject(
  CommunityCatalog catalog,
  PackProjectReference reference,
  CancellationToken token,
) async {
  if (reference.source == ContentSource.modrinth ||
      RegExp(r'^\d+$').hasMatch(reference.id)) {
    final project = await catalog.project(
      reference.source,
      reference.id,
      ContentKind.modpack,
      token,
    );
    if (project.kind != ContentKind.modpack) {
      throw const FormatException('所选项目不是整合包。');
    }
    return project;
  }
  return catalog.projectBySlug(
    reference.source,
    reference.id,
    ContentKind.modpack,
    token,
  );
}

Json linkedPackRecord(
  Json current,
  ContentProject project, {
  ContentVersion? installed,
}) {
  if (project.kind != ContentKind.modpack ||
      project.id.isEmpty ||
      project.id.startsWith('local-') ||
      installed != null &&
          (installed.source != project.source ||
              installed.projectId != project.id)) {
    throw const FormatException('整合包来源与发布版本不匹配。');
  }
  return {
    ...current,
    'originSource': current['originSource'] ?? current['source'],
    'originReleaseId': current['originReleaseId'] ?? current['releaseId'],
    if (importedPackHash(current) != null)
      'importedArchiveSha256': importedPackHash(current),
    'source': project.source.name,
    'projectId': project.id,
    'releaseId': installed?.id ?? '',
    'website': project.website,
  };
}
