import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:push_kit/src/setup/push_kit_configurator.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('push_kit_setup_');
    File('${root.path}/pubspec.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('name: host\n');
    File('${root.path}/ios/Runner/Info.plist')
      ..createSync(recursive: true)
      ..writeAsStringSync(_infoPlist);
    File('${root.path}/ios/Runner/Runner.entitlements')
      ..createSync(recursive: true)
      ..writeAsStringSync(_productionEntitlements);
    File('${root.path}/ios/Runner.xcodeproj/project.pbxproj')
      ..createSync(recursive: true)
      ..writeAsStringSync(_projectWithRunnerEntitlements);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<PushKitSetupResult> configure({String? apsEnvironment}) =>
      PushKitConfigurator().configure(
        PushKitSetupOptions(
          projectRoot: root,
          platforms: const <PushKitSetupPlatform>{PushKitSetupPlatform.ios},
          apsEnvironment: apsEnvironment,
        ),
      );

  test(
    'preserves an existing APNs environment when none is requested',
    () async {
      final File entitlements = File(
        '${root.path}/ios/Runner/Runner.entitlements',
      );
      final String before = entitlements.readAsStringSync();

      final PushKitSetupResult result = await configure();

      expect(result.hasPendingChanges, isFalse);
      expect(entitlements.readAsStringSync(), before);
      expect(
        entitlements.readAsStringSync(),
        contains('<string>production</string>'),
      );
    },
  );

  test(
    'changes an existing APNs environment only when explicitly requested',
    () async {
      await configure(apsEnvironment: 'development');

      expect(
        File('${root.path}/ios/Runner/Runner.entitlements').readAsStringSync(),
        contains('<string>development</string>'),
      );
    },
  );

  test('uses development only when the APNs entitlement is missing', () async {
    final File entitlements = File(
      '${root.path}/ios/Runner/Runner.entitlements',
    )..deleteSync();

    await configure();

    expect(
      entitlements.readAsStringSync(),
      contains('<string>development</string>'),
    );
  });

  test('updates only the configured target entitlement path', () async {
    final File project = File(
      '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
    )..writeAsStringSync(_projectWithoutRunnerEntitlements);

    final PushKitSetupResult first = await configure();
    final String configured = project.readAsStringSync();

    expect(first.hasPendingChanges, isTrue);
    expect(
      'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;'.allMatches(
        configured,
      ),
      hasLength(1),
    );
    expect(
      configured,
      contains(
        'CODE_SIGN_ENTITLEMENTS = RunnerTests/RunnerTests.entitlements;',
      ),
    );

    final PushKitSetupResult second = await configure();
    expect(second.hasPendingChanges, isFalse);
  });
}

const String _infoPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>UIBackgroundModes</key><array><string>remote-notification</string></array>
</dict></plist>
''';

const String _productionEntitlements = '''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>aps-environment</key><string>production</string>
</dict></plist>
''';

const String _projectWithRunnerEntitlements = '''buildSettings = {
  INFOPLIST_FILE = Runner/Info.plist;
  CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;
};
buildSettings = {
  INFOPLIST_FILE = RunnerTests/Info.plist;
  CODE_SIGN_ENTITLEMENTS = RunnerTests/RunnerTests.entitlements;
};
''';

const String _projectWithoutRunnerEntitlements = '''buildSettings = {
  INFOPLIST_FILE = Runner/Info.plist;
};
buildSettings = {
  INFOPLIST_FILE = RunnerTests/Info.plist;
  CODE_SIGN_ENTITLEMENTS = RunnerTests/RunnerTests.entitlements;
};
''';
