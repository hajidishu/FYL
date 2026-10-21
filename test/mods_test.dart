import 'package:flutter_test/flutter_test.dart';
import 'package:free_your_launcher/core/install_options.dart';
import 'package:free_your_launcher/core/minecraft.dart';
import 'package:free_your_launcher/core/mod_catalog.dart';

void main() {
  test('Fabric plus OptiFine requires explicitly selected OptiFabric', () {
    const fabric = LoaderVersion(ModLoader.fabric, '0.16.10');
    const optifine = OptiFineVersion('OptiFine_1.20.1_HD_U_I6.jar');
    const bridge = CompatibilityMod(
      version: '1.14.3',
      fileName: 'optifabric.jar',
      url: 'https://mediafilez.forgecdn.net/test.jar',
    );
    expect(
      const InstallOptions(loader: fabric, optifine: optifine).validationError,
      contains('OptiFabric'),
    );
    expect(
      const InstallOptions(
        loader: fabric,
        optifine: optifine,
        optifabric: bridge,
      ).validationError,
      isNull,
    );
    expect(const InstallOptions(optifabric: bridge).validationError, isNotNull);
    expect(
      const InstallOptions(
        loader: LoaderVersion(ModLoader.neoforge, '21.1.1'),
        optifine: optifine,
      ).validationError,
      contains('NeoForge'),
    );
    expect(const InstallOptions().isVanilla, isTrue);
  });
  test('Maven paths include classifier and extension for Forge processors', () {
    expect(
      mavenPath('net.neoforged:neoform:1.21.1-20240808@zip'),
      'net/neoforged/neoform/1.21.1-20240808/neoform-1.21.1-20240808.zip',
    );
    expect(
      mavenPath('net.minecraft:client:1.21.1:mappings@tsrg'),
      'net/minecraft/client/1.21.1/client-1.21.1-mappings.tsrg',
    );
    expect(
      mavenPath('net.neoforged:AutoRenamingTool:2.0.3:all'),
      'net/neoforged/AutoRenamingTool/2.0.3/AutoRenamingTool-2.0.3-all.jar',
    );
  });
  test(
    'loader profiles append launch arguments and replace matching libraries',
    () {
      final result = mergeVersionProfiles(
        {
          'id': '1.21.1',
          'mainClass': 'Vanilla',
          'arguments': {
            'game': ['--username', r'${auth_player_name}'],
            'jvm': ['-cp', r'${classpath}'],
          },
          'libraries': [
            {'name': 'org.asm:asm:9.7'},
            {'name': 'org.lwjgl:lwjgl:3.3.3:natives-windows'},
          ],
          'assetIndex': {'id': '17'},
        },
        {
          'id': 'forge-52',
          'inheritsFrom': '1.21.1',
          'mainClass': 'ForgeMain',
          'arguments': {
            'game': ['--launchTarget', 'forgeclient'],
            'jvm': ['--add-modules', 'ALL-MODULE-PATH'],
          },
          'libraries': [
            {'name': 'org.asm:asm:9.10'},
            {'name': 'net.minecraftforge:forge:52:client'},
          ],
        },
      );
      expect(result['mainClass'], 'ForgeMain');
      expect(result['inheritsFrom'], isNull);
      expect(result['arguments']['game'], [
        '--username',
        r'${auth_player_name}',
        '--launchTarget',
        'forgeclient',
      ]);
      expect((result['libraries'] as List).map((row) => row['name']), [
        'org.asm:asm:9.10',
        'org.lwjgl:lwjgl:3.3.3:natives-windows',
        'net.minecraftforge:forge:52:client',
      ]);
      expect(result['assetIndex']['id'], '17');
    },
  );
  test(
    'legacy OptiFine and Forge profiles replace the legacy game argument string',
    () {
      final result = mergeVersionProfiles(
        {
          'mainClass': 'Vanilla',
          'arguments': {
            'jvm': [],
            'game': ['--old'],
          },
          'libraries': [],
        },
        {
          'mainClass': 'net.minecraft.launchwrapper.Launch',
          'minecraftArguments': '--tweakClass optifine.OptiFineTweaker',
          'libraries': [],
        },
      );
      expect(result.containsKey('arguments'), isFalse);
      expect(result['minecraftArguments'], contains('OptiFineTweaker'));
    },
  );
}
