import 'dart:io';

import 'package:args/args.dart';
import 'package:push_kit/src/setup/push_kit_configurator.dart';

Future<void> main(List<String> arguments) async {
  final ArgParser parser =
      ArgParser()
        ..addOption(
          'project',
          abbr: 'p',
          defaultsTo: '.',
          help: 'Flutter host project root.',
        )
        ..addOption(
          'platforms',
          defaultsTo: 'android',
          help: 'Comma-separated platforms: android,ios.',
        )
        ..addOption('hms-app-id', help: 'Huawei App ID.')
        ..addOption('hms-services', help: 'Path to agconnect-services.json.')
        ..addOption('mi-app-id', help: 'Xiaomi App ID.')
        ..addOption('mi-app-key', help: 'Xiaomi App Key.')
        ..addOption('oppo-app-key', help: 'OPPO App Key.')
        ..addOption('oppo-app-secret', help: 'OPPO App Secret.')
        ..addOption('vivo-app-id', help: 'vivo App ID.')
        ..addOption('vivo-app-key', help: 'vivo API Key.')
        ..addOption(
          'android-manifest',
          help: 'Override AndroidManifest.xml path.',
        )
        ..addOption(
          'android-values',
          help: 'Override generated Android values XML path.',
        )
        ..addOption('ios-info-plist', help: 'Override iOS Info.plist path.')
        ..addOption('ios-entitlements', help: 'Override iOS entitlements path.')
        ..addOption(
          'aps-environment',
          allowed: <String>['development', 'production'],
          help:
              'APNs environment. Omit to preserve an existing value; a new entitlement defaults to development.',
        )
        ..addFlag(
          'dry-run',
          negatable: false,
          help: 'Preview changes without writing.',
        )
        ..addFlag(
          'check',
          negatable: false,
          help: 'Exit 2 when configuration changes are required.',
        )
        ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

  late final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln('push_kit setup: ${error.message}\n\n${_usage(parser)}');
    exitCode = 64;
    return;
  }
  if (args.flag('help')) {
    stdout.writeln(_usage(parser));
    return;
  }

  try {
    final Directory root = Directory(args.option('project')!).absolute;
    late final Set<PushKitSetupPlatform> platforms;
    try {
      platforms = _parsePlatforms(args.option('platforms')!);
    } on FormatException catch (error) {
      stderr.writeln('push_kit setup: ${error.message}');
      exitCode = 64;
      return;
    }
    final PushKitSetupOptions options = PushKitSetupOptions(
      projectRoot: root,
      platforms: platforms,
      hmsAppId: args.option('hms-app-id'),
      hmsServices: _resolveFile(root, args.option('hms-services')),
      miAppId: args.option('mi-app-id'),
      miAppKey: args.option('mi-app-key'),
      oppoAppKey: args.option('oppo-app-key'),
      oppoAppSecret: args.option('oppo-app-secret'),
      vivoAppId: args.option('vivo-app-id'),
      vivoAppKey: args.option('vivo-app-key'),
      androidManifest: _resolveFile(root, args.option('android-manifest')),
      androidValues: _resolveFile(root, args.option('android-values')),
      iosInfoPlist: _resolveFile(root, args.option('ios-info-plist')),
      iosEntitlements: _resolveFile(root, args.option('ios-entitlements')),
      apsEnvironment: args.option('aps-environment'),
      dryRun: args.flag('dry-run'),
      checkOnly: args.flag('check'),
    );
    final PushKitSetupResult result = await PushKitConfigurator().configure(
      options,
    );
    final bool preview = options.dryRun || options.checkOnly;
    stdout.writeln(
      result.hasPendingChanges
          ? 'push_kit: ${preview ? 'host configuration changes are required.' : 'host configuration updated.'}'
          : 'push_kit: host configuration is already up to date.',
    );
    for (final File file in result.changedFiles) {
      stdout.writeln('  ${preview ? 'would update' : 'updated'} ${file.path}');
    }
    for (final String message in result.messages) {
      stdout.writeln('  - $message');
    }
    if (options.checkOnly && result.hasPendingChanges) exitCode = 2;
  } on Object catch (error) {
    stderr.writeln('push_kit setup failed: $error');
    exitCode = 1;
  }
}

Set<PushKitSetupPlatform> _parsePlatforms(String value) {
  final Set<PushKitSetupPlatform> result = <PushKitSetupPlatform>{};
  for (final String raw in value.split(',')) {
    switch (raw.trim().toLowerCase()) {
      case 'android':
        result.add(PushKitSetupPlatform.android);
      case 'ios':
        result.add(PushKitSetupPlatform.ios);
      case '':
        break;
      default:
        throw FormatException('Unsupported platform: ${raw.trim()}');
    }
  }
  if (result.isEmpty) {
    throw FormatException('At least one platform must be selected');
  }
  return result;
}

File? _resolveFile(Directory root, String? value) {
  final String path = value?.trim() ?? '';
  if (path.isEmpty) return null;
  final bool windowsAbsolute =
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  final bool absolute = windowsAbsolute || Uri.file(path).isAbsolute;
  return absolute ? File(path) : File('${root.path}/$path');
}

String _usage(ArgParser parser) => '''Configure a Flutter host for push_kit.

Usage:
  dart run push_kit:setup --project . \\
    --mi-app-id <id> --mi-app-key <key> \\
    --oppo-app-key <key> --oppo-app-secret <secret>

Use --dry-run to preview changes and --check in CI. Vivo initialization also
requires an explicit Dart consent argument, for example
`PushKit.vivoInit(true)` after the host privacy statement is accepted.

${parser.usage}''';
