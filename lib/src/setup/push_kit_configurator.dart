import 'dart:io';

import 'package:xml/xml.dart';

enum PushKitSetupPlatform { android, ios }

class PushKitSetupOptions {
  const PushKitSetupOptions({
    required this.projectRoot,
    required this.platforms,
    this.hmsAppId,
    this.hmsServices,
    this.miAppId,
    this.miAppKey,
    this.oppoAppKey,
    this.oppoAppSecret,
    this.vivoAppId,
    this.vivoAppKey,
    this.androidManifest,
    this.androidValues,
    this.iosInfoPlist,
    this.iosEntitlements,
    this.dryRun = false,
    this.checkOnly = false,
  });

  final Directory projectRoot;
  final Set<PushKitSetupPlatform> platforms;
  final String? hmsAppId;
  final File? hmsServices;
  final String? miAppId;
  final String? miAppKey;
  final String? oppoAppKey;
  final String? oppoAppSecret;
  final String? vivoAppId;
  final String? vivoAppKey;
  final File? androidManifest;
  final File? androidValues;
  final File? iosInfoPlist;
  final File? iosEntitlements;
  final bool dryRun;
  final bool checkOnly;
}

class PushKitSetupResult {
  const PushKitSetupResult({
    required this.changedFiles,
    required this.messages,
    required this.hasPendingChanges,
  });
  final List<File> changedFiles;
  final List<String> messages;
  final bool hasPendingChanges;
}

class PushKitConfigurator {
  Future<PushKitSetupResult> configure(PushKitSetupOptions options) async {
    _validate(options);
    final List<File> changed = <File>[];
    final List<String> messages = <String>[];
    bool pending = false;
    final bool write = !options.dryRun && !options.checkOnly;

    if (options.platforms.contains(PushKitSetupPlatform.android)) {
      final File manifest =
          options.androidManifest ??
          File(
            '${options.projectRoot.path}/android/app/src/main/AndroidManifest.xml',
          );
      final File values =
          options.androidValues ??
          File(
            '${options.projectRoot.path}/android/app/src/main/res/values/push_kit.xml',
          );
      final Map<String, String> valuesMap = <String, String>{
        'HMS_APP_ID': options.hmsAppId ?? '',
        'MiPushAppId': options.miAppId ?? '',
        'MiPushAppKey': options.miAppKey ?? '',
        'OPPOPushAppKey': options.oppoAppKey ?? '',
        'OPPOPushAppSecret': options.oppoAppSecret ?? '',
        'com.vivo.push.app_id': options.vivoAppId ?? '',
        'com.vivo.push.api_key': options.vivoAppKey ?? '',
      }..removeWhere((String key, String value) => value.isEmpty);
      final bool manifestChanged = _configureManifest(
        manifest,
        valuesMap,
        write: write,
      );
      final bool valuesChanged = _configureValues(
        values,
        valuesMap,
        write: write,
      );
      pending |= manifestChanged || valuesChanged;
      if (manifestChanged) changed.add(manifest);
      if (valuesChanged) changed.add(values);
      if (options.hmsServices != null) {
        if (!options.hmsServices!.existsSync()) {
          throw StateError(
            'Huawei services file not found: ${options.hmsServices!.path}',
          );
        }
        final File target = File(
          '${options.projectRoot.path}/android/app/agconnect-services.json',
        );
        final bool copyChanged =
            !target.existsSync() ||
            target.readAsBytesSync().toString() !=
                options.hmsServices!.readAsBytesSync().toString();
        pending |= copyChanged;
        if (copyChanged) {
          changed.add(target);
          if (write) {
            target.parent.createSync(recursive: true);
            target.writeAsBytesSync(options.hmsServices!.readAsBytesSync());
          }
        }
      }
      messages.add('Android: generated vendor metadata and resource values.');
      messages.add(
        'Android: add only the vendor credentials you use; do not commit secrets.',
      );
    }

    if (options.platforms.contains(PushKitSetupPlatform.ios)) {
      final File info =
          options.iosInfoPlist ??
          File('${options.projectRoot.path}/ios/Runner/Info.plist');
      final File entitlements =
          options.iosEntitlements ??
          File('${options.projectRoot.path}/ios/Runner/Runner.entitlements');
      final bool infoChanged = _configureInfoPlist(info, write: write);
      final bool entitlementChanged = _configureEntitlements(
        entitlements,
        write: write,
      );
      final File projectFile = File(
        '${options.projectRoot.path}/ios/Runner.xcodeproj/project.pbxproj',
      );
      final String entitlementPath = _relativeToIos(
        options.projectRoot,
        entitlements,
      );
      final bool projectChanged = _configureXcodeProject(
        projectFile,
        entitlementPath,
        write: write,
      );
      pending |= infoChanged || entitlementChanged || projectChanged;
      if (infoChanged) changed.add(info);
      if (entitlementChanged) changed.add(entitlements);
      if (projectChanged) changed.add(projectFile);
      messages.add(
        'iOS: enabled remote-notification background mode and APNs entitlement.',
      );
      messages.add(
        'iOS: finish Push Notifications capability and signing in Xcode.',
      );
    }
    return PushKitSetupResult(
      changedFiles: changed,
      messages: messages,
      hasPendingChanges: pending,
    );
  }

  void _validate(PushKitSetupOptions options) {
    if (!File('${options.projectRoot.path}/pubspec.yaml').existsSync()) {
      throw ArgumentError('Not a Flutter project: ${options.projectRoot.path}');
    }
    if (options.platforms.isEmpty) {
      throw ArgumentError('At least one platform must be selected.');
    }
    if (options.platforms.contains(PushKitSetupPlatform.android)) {
      if (options.hmsAppId == null &&
          options.miAppId == null &&
          options.oppoAppKey == null &&
          options.vivoAppId == null) {
        throw ArgumentError(
          'Android setup requires at least one vendor credential.',
        );
      }
      if ((options.miAppId == null) != (options.miAppKey == null)) {
        throw ArgumentError('Both --mi-app-id and --mi-app-key are required.');
      }
      if ((options.oppoAppKey == null) != (options.oppoAppSecret == null)) {
        throw ArgumentError(
          'Both --oppo-app-key and --oppo-app-secret are required.',
        );
      }
      if ((options.vivoAppId == null) != (options.vivoAppKey == null)) {
        throw ArgumentError(
          'Both --vivo-app-id and --vivo-app-key are required.',
        );
      }
    }
  }

  bool _configureManifest(
    File file,
    Map<String, String> credentials, {
    required bool write,
  }) {
    if (!file.existsSync()) {
      throw StateError('AndroidManifest.xml not found: ${file.path}');
    }
    final XmlDocument document = XmlDocument.parse(file.readAsStringSync());
    final XmlElement application =
        document.findAllElements('application').first;
    bool changed = false;
    for (final MapEntry<String, String> entry in credentials.entries) {
      final String resourceName = _resourceName(entry.key);
      final String value = '@string/$resourceName';
      XmlElement? metadata;
      for (final XmlElement element in application.findElements('meta-data')) {
        if (element.getAttribute('name') == entry.key) {
          metadata = element;
          break;
        }
      }
      if (metadata == null) {
        metadata = XmlElement(XmlName('meta-data'), <XmlAttribute>[
          XmlAttribute(XmlName('name', 'android'), entry.key),
          XmlAttribute(XmlName('value', 'android'), value),
        ], <XmlNode>[]);
        application.children.add(metadata);
        changed = true;
      } else if (metadata.getAttribute('value') != value) {
        metadata.setAttribute('value', value);
        changed = true;
      }
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  bool _configureValues(
    File file,
    Map<String, String> credentials, {
    required bool write,
  }) {
    final XmlDocument document =
        file.existsSync()
            ? XmlDocument.parse(file.readAsStringSync())
            : XmlDocument.parse('<resources/>');
    final XmlElement resources = document.rootElement;
    bool changed = false;
    for (final MapEntry<String, String> entry in credentials.entries) {
      final String name = _resourceName(entry.key);
      XmlElement? node;
      for (final XmlElement child in resources.findElements('string')) {
        if (child.getAttribute('name') == name) node = child;
      }
      if (node == null) {
        resources.children.add(
          XmlElement(
            XmlName('string'),
            <XmlAttribute>[XmlAttribute(XmlName('name'), name)],
            <XmlNode>[XmlText(entry.value)],
          ),
        );
        changed = true;
      } else if (node.innerText != entry.value) {
        node.children.clear();
        node.children.add(XmlText(entry.value));
        changed = true;
      }
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  String _resourceName(String key) =>
      'push_kit_${key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

  bool _configureInfoPlist(File file, {required bool write}) {
    if (!file.existsSync()) {
      throw StateError('Info.plist not found: ${file.path}');
    }
    final XmlDocument document = XmlDocument.parse(file.readAsStringSync());
    final XmlElement dict = document.findAllElements('dict').first;
    final XmlElement? existing = _plistValue(dict, 'UIBackgroundModes');
    final XmlElement array = existing ?? XmlElement(XmlName('array'));
    bool changed = false;
    if (existing == null) {
      _plistAppend(dict, 'UIBackgroundModes', array);
      changed = true;
    }
    if (!array
        .findElements('string')
        .any((XmlElement e) => e.innerText == 'remote-notification')) {
      array.children.add(
        XmlElement(XmlName('string'), <XmlAttribute>[], <XmlNode>[
          XmlText('remote-notification'),
        ]),
      );
      changed = true;
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  bool _configureEntitlements(File file, {required bool write}) {
    final XmlDocument document =
        file.existsSync()
            ? XmlDocument.parse(file.readAsStringSync())
            : XmlDocument.parse(
              '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
            );
    final XmlElement dict = document.findAllElements('dict').first;
    final XmlElement? existing = _plistValue(dict, 'aps-environment');
    bool changed = false;
    if (existing == null) {
      _plistAppend(
        dict,
        'aps-environment',
        XmlElement(XmlName('string'), <XmlAttribute>[], <XmlNode>[
          XmlText('development'),
        ]),
      );
      changed = true;
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  XmlElement? _plistValue(XmlElement dict, String key) {
    final List<XmlElement> children = dict.childElements.toList();
    for (int i = 0; i + 1 < children.length; i++) {
      if (children[i].name.local == 'key' && children[i].innerText == key) {
        return children[i + 1];
      }
    }
    return null;
  }

  void _plistAppend(XmlElement dict, String key, XmlElement value) {
    dict.children.add(
      XmlElement(XmlName('key'), <XmlAttribute>[], <XmlNode>[XmlText(key)]),
    );
    dict.children.add(value);
  }

  String _relativeToIos(Directory root, File file) {
    final String iosRoot = '${root.path}/ios/';
    if (file.path.startsWith(iosRoot)) {
      return file.path.substring(iosRoot.length);
    }
    return 'Runner/Runner.entitlements';
  }

  bool _configureXcodeProject(
    File file,
    String entitlementPath, {
    required bool write,
  }) {
    if (!file.existsSync()) {
      throw StateError('Xcode project file not found: ${file.path}');
    }
    final String source = file.readAsStringSync();
    if (source.contains('CODE_SIGN_ENTITLEMENTS = ')) return false;
    final String updated = source.replaceAll(
      'INFOPLIST_FILE = Runner/Info.plist;',
      'INFOPLIST_FILE = Runner/Info.plist;\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = $entitlementPath;',
    );
    if (updated == source) return false;
    if (write) file.writeAsStringSync(updated);
    return true;
  }

  void _writeXml(File file, XmlDocument document) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${document.toXmlString(pretty: true, indent: '\t')}\n',
    );
  }
}
