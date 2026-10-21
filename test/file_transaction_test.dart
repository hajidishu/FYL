import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/file_transaction.dart';
import 'package:free_your_launcher/core/network.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory root;
  late Directory source;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('fyl-file-transaction-');
    root = Directory(p.join(temp.path, 'root'))..createSync();
    source = Directory(p.join(temp.path, 'source'))..createSync();
  });

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<File> sourceFile(String name, String contents) async {
    final file = File(p.join(source.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  Future<File> targetFile(String name, String contents) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsString(contents);
  }

  test(
    'cancellation after a committed file restores the previous tree',
    () async {
      final firstSource = await sourceFile('first.jar', 'new first');
      final secondSource = await sourceFile('second.jar', 'new second');
      final firstTarget = await targetFile('mods/first.jar', 'old first');
      final secondTarget = File(p.join(root.path, 'mods/second.jar'));
      final token = CancellationToken();

      await expectLater(
        publishFiles(
          root.path,
          [
            (firstSource.path, firstTarget.path),
            (secondSource.path, secondTarget.path),
          ],
          token,
          onProgress: (done, _) {
            if (done == 1) token.cancel();
          },
        ),
        throwsA(isA<Cancelled>()),
      );

      expect(await firstTarget.readAsString(), 'old first');
      expect(await secondTarget.exists(), isFalse);
      expect(
        root
            .listSync(recursive: true)
            .where((entity) => p.basename(entity.path).contains('.fyl-')),
        isEmpty,
      );
    },
  );

  test('cancellation rolls back replacements and removals together', () async {
    final replacement = await sourceFile('replacement.jar', 'replacement');
    final replacedTarget = await targetFile('mods/replace.jar', 'original');
    final removedTarget = await targetFile('mods/remove.jar', 'keep me');
    final token = CancellationToken();

    await expectLater(
      publishFiles(
        root.path,
        [(replacement.path, replacedTarget.path)],
        token,
        removals: [removedTarget.path],
        onProgress: (done, _) {
          if (done == 1) token.cancel();
        },
      ),
      throwsA(isA<Cancelled>()),
    );

    expect(await replacedTarget.readAsString(), 'original');
    expect(await removedTarget.readAsString(), 'keep me');
  });

  test('successful publish replaces, adds, and removes files', () async {
    final replacement = await sourceFile('replacement.jar', 'new');
    final added = await sourceFile('added.jar', 'added');
    final replacedTarget = await targetFile('mods/replace.jar', 'old');
    final removedTarget = await targetFile('mods/remove.jar', 'remove');

    await publishFiles(
      root.path,
      [
        (replacement.path, replacedTarget.path),
        (added.path, p.join(root.path, 'mods/added.jar')),
      ],
      CancellationToken(),
      removals: [removedTarget.path],
    );

    expect(await replacedTarget.readAsString(), 'new');
    expect(
      await File(p.join(root.path, 'mods/added.jar')).readAsString(),
      'added',
    );
    expect(await removedTarget.exists(), isFalse);
    expect(
      root
          .listSync(recursive: true)
          .where((entity) => p.basename(entity.path).contains('.fyl-')),
      isEmpty,
    );
  });

  test('finalize failure restores replacements and removals', () async {
    final replacement = await sourceFile('replacement.jar', 'replacement');
    final replacedTarget = await targetFile('mods/replace.jar', 'original');
    final removedTarget = await targetFile('mods/remove.jar', 'keep me');

    await expectLater(
      publishFiles(
        root.path,
        [(replacement.path, replacedTarget.path)],
        CancellationToken(),
        removals: [removedTarget.path],
        finalize: () async => throw StateError('configuration save failed'),
      ),
      throwsStateError,
    );

    expect(await replacedTarget.readAsString(), 'original');
    expect(await removedTarget.readAsString(), 'keep me');
  });

  test(
    'rejects duplicate destinations and directory targets before commit',
    () async {
      final first = await sourceFile('first.jar', 'one');
      final second = await sourceFile('second.jar', 'two');
      final duplicate = p.join(root.path, 'mods/shared.jar');

      await expectLater(
        publishFiles(root.path, [
          (first.path, duplicate),
          (second.path, duplicate),
        ], CancellationToken()),
        throwsFormatException,
      );
      expect(await File(duplicate).exists(), isFalse);

      final directoryTarget = Directory(p.join(root.path, 'mods/folder'))
        ..createSync(recursive: true);
      await expectLater(
        publishFiles(root.path, [
          (first.path, directoryTarget.path),
        ], CancellationToken()),
        throwsFormatException,
      );
      expect(await directoryTarget.exists(), isTrue);
    },
  );
}
