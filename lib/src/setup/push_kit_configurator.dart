import 'dart:convert';
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
    this.apsEnvironment,
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

  /// An explicitly requested APNs environment. When omitted, an existing
  /// host entitlement is preserved and a missing one defaults to development.
  final String? apsEnvironment;
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
    final bool write = !options.dryRun && !options.checkOnly;
    final Map<String, _FileSnapshot> snapshots =
        write
            ? _takeSnapshots(_candidateFiles(options))
            : <String, _FileSnapshot>{};
    try {
      return _configure(options, write: write);
    } on Object {
      if (write) _restoreSnapshots(snapshots);
      rethrow;
    }
  }

  PushKitSetupResult _configure(
    PushKitSetupOptions options, {
    required bool write,
  }) {
    final List<File> changed = <File>[];
    final List<String> messages = <String>[];
    bool pending = false;
    final Directory root = options.projectRoot.absolute;

    if (options.platforms.contains(PushKitSetupPlatform.android)) {
      final File manifest = _fileOrDefault(
        root,
        options.androidManifest,
        'android/app/src/main/AndroidManifest.xml',
      );
      final File values = _fileOrDefault(
        root,
        options.androidValues,
        'android/app/src/main/res/values/push_kit.xml',
      );
      final Map<String, String> valuesMap = <String, String>{
        'HMS_APP_ID': _clean(options.hmsAppId),
        'MiPushAppId': _clean(options.miAppId),
        'MiPushAppKey': _clean(options.miAppKey),
        'OPPOPushAppKey': _clean(options.oppoAppKey),
        'OPPOPushAppSecret': _clean(options.oppoAppSecret),
        'com.vivo.push.app_id': _clean(options.vivoAppId),
        'com.vivo.push.api_key': _clean(options.vivoAppKey),
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
        final File source = _absoluteInputFile(root, options.hmsServices!);
        if (!source.existsSync() ||
            FileSystemEntity.typeSync(source.path) !=
                FileSystemEntityType.file) {
          throw StateError('Huawei services file not found: ${source.path}');
        }
        final File target = File(
          '${root.path}/android/app/agconnect-services.json',
        );
        final List<int> sourceBytes = source.readAsBytesSync();
        final bool copyChanged =
            !target.existsSync() ||
            !_sameBytes(target.readAsBytesSync(), sourceBytes);
        pending |= copyChanged;
        if (copyChanged) {
          changed.add(target);
          if (write) {
            target.parent.createSync(recursive: true);
            target.writeAsBytesSync(sourceBytes);
          }
        }
      }
      messages.add('Android: generated vendor metadata and resource values.');
      messages.add(
        'Android: add only the vendor credentials you use; do not commit secrets.',
      );
    }

    if (options.platforms.contains(PushKitSetupPlatform.ios)) {
      final File info = _fileOrDefault(
        root,
        options.iosInfoPlist,
        'ios/Runner/Info.plist',
      );
      final File entitlements = _fileOrDefault(
        root,
        options.iosEntitlements,
        'ios/Runner/Runner.entitlements',
      );
      final File projectFile = File(
        '${root.path}/ios/Runner.xcodeproj/project.pbxproj',
      );
      if (!info.existsSync()) {
        throw StateError('Info.plist not found: ${info.path}');
      }
      if (!projectFile.existsSync()) {
        throw StateError('Xcode project file not found: ${projectFile.path}');
      }
      final bool infoChanged = _configureInfoPlist(info, write: write);
      final bool entitlementChanged = _configureEntitlements(
        entitlements,
        environment: options.apsEnvironment?.trim(),
        write: write,
      );
      final String infoPlistPath = _relativeToIos(root, info);
      final String entitlementPath = _relativeToIos(root, entitlements);
      final bool projectChanged = _configureXcodeProject(
        projectFile,
        infoPlistPath: infoPlistPath,
        entitlementPath: entitlementPath,
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
    final Directory root = options.projectRoot.absolute;
    if (!root.existsSync() || !File('${root.path}/pubspec.yaml').existsSync()) {
      throw ArgumentError('Not a Flutter project: ${root.path}');
    }
    if (options.platforms.isEmpty) {
      throw ArgumentError('At least one platform must be selected.');
    }
    final String? environment = options.apsEnvironment?.trim();
    if (environment != null &&
        !<String>{'development', 'production'}.contains(environment)) {
      throw ArgumentError(
        'APNs environment must be development or production.',
      );
    }
    if (!options.platforms.contains(PushKitSetupPlatform.android)) return;

    final bool hasAndroidCredential =
        !_isBlank(options.hmsAppId) ||
        options.hmsServices != null ||
        !_isBlank(options.miAppId) ||
        !_isBlank(options.oppoAppKey) ||
        !_isBlank(options.vivoAppId);
    if (!hasAndroidCredential) {
      throw ArgumentError(
        'Android setup requires at least one non-empty vendor credential.',
      );
    }
    _validatePair(
      options.miAppId,
      options.miAppKey,
      '--mi-app-id',
      '--mi-app-key',
    );
    _validatePair(
      options.oppoAppKey,
      options.oppoAppSecret,
      '--oppo-app-key',
      '--oppo-app-secret',
    );
    _validatePair(
      options.vivoAppId,
      options.vivoAppKey,
      '--vivo-app-id',
      '--vivo-app-key',
    );
    if (options.hmsServices != null) {
      final File services = _absoluteInputFile(root, options.hmsServices!);
      if (!services.existsSync() ||
          FileSystemEntity.typeSync(services.path) !=
              FileSystemEntityType.file) {
        throw ArgumentError('Huawei services file not found: ${services.path}');
      }
      try {
        final String json = services.readAsStringSync().replaceFirst(
          '\uFEFF',
          '',
        );
        if (jsonDecode(json) is! Map) {
          throw const FormatException('root must be an object');
        }
      } on Object catch (error) {
        throw ArgumentError(
          'Huawei services file is not valid JSON at ${services.path}: $error',
        );
      }
    }
  }

  void _validatePair(
    String? first,
    String? second,
    String firstName,
    String secondName,
  ) {
    final bool firstPresent = !_isBlank(first);
    final bool secondPresent = !_isBlank(second);
    if (firstPresent != secondPresent) {
      throw ArgumentError('Both $firstName and $secondName are required.');
    }
  }

  Map<String, _FileSnapshot> _takeSnapshots(List<File> files) {
    final Map<String, _FileSnapshot> snapshots = <String, _FileSnapshot>{};
    for (final File input in files) {
      final File file = input.absolute;
      final String path = file.path;
      if (snapshots.containsKey(path)) continue;
      if (file.existsSync() &&
          FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
        throw StateError('Expected a regular file: $path');
      }
      snapshots[path] = _FileSnapshot(
        file,
        file.existsSync() ? file.readAsBytesSync() : null,
      );
    }
    return snapshots;
  }

  void _restoreSnapshots(Map<String, _FileSnapshot> snapshots) {
    for (final _FileSnapshot snapshot in snapshots.values) {
      try {
        if (snapshot.bytes == null) {
          if (snapshot.file.existsSync()) snapshot.file.deleteSync();
        } else {
          snapshot.file.parent.createSync(recursive: true);
          snapshot.file.writeAsBytesSync(snapshot.bytes!);
        }
      } on Object {
        // Preserve the original configuration error; the report can still
        // identify a failed rollback from the filesystem state.
      }
    }
  }

  List<File> _candidateFiles(PushKitSetupOptions options) {
    final Directory root = options.projectRoot.absolute;
    final List<File> files = <File>[];
    if (options.platforms.contains(PushKitSetupPlatform.android)) {
      files.add(
        _fileOrDefault(
          root,
          options.androidManifest,
          'android/app/src/main/AndroidManifest.xml',
        ),
      );
      files.add(
        _fileOrDefault(
          root,
          options.androidValues,
          'android/app/src/main/res/values/push_kit.xml',
        ),
      );
      if (options.hmsServices != null) {
        files.add(File('${root.path}/android/app/agconnect-services.json'));
      }
    }
    if (options.platforms.contains(PushKitSetupPlatform.ios)) {
      files.add(
        _fileOrDefault(root, options.iosInfoPlist, 'ios/Runner/Info.plist'),
      );
      files.add(
        _fileOrDefault(
          root,
          options.iosEntitlements,
          'ios/Runner/Runner.entitlements',
        ),
      );
      files.add(File('${root.path}/ios/Runner.xcodeproj/project.pbxproj'));
    }
    return files;
  }

  bool _configureManifest(
    File file,
    Map<String, String> credentials, {
    required bool write,
  }) {
    final XmlDocument document = _parseXmlFile(file, 'AndroidManifest.xml');
    if (document.rootElement.name.local != 'manifest') {
      throw StateError(
        'Android manifest root must be <manifest>: ${file.path}',
      );
    }
    final List<XmlElement> applications =
        document.rootElement.findElements('application').toList();
    final XmlElement? application =
        applications.isEmpty ? null : applications.first;
    if (application == null) {
      throw StateError(
        'AndroidManifest.xml does not contain an <application> element: ${file.path}',
      );
    }

    bool changed = false;
    for (final MapEntry<String, String> entry in credentials.entries) {
      final String value = '@string/${_resourceName(entry.key)}';
      final List<XmlElement> matching =
          application
              .findElements('meta-data')
              .where(
                (XmlElement element) =>
                    element.getAttribute('name', namespace: '*') == entry.key,
              )
              .toList();
      XmlElement metadata;
      if (matching.isEmpty) {
        metadata = XmlElement(XmlName('meta-data'), <XmlAttribute>[
          XmlAttribute(XmlName('name', 'android'), entry.key),
          XmlAttribute(XmlName('value', 'android'), value),
        ], <XmlNode>[]);
        application.children.add(metadata);
        changed = true;
      } else {
        metadata = matching.first;
        final XmlAttribute? valueAttribute = metadata.getAttributeNode(
          'value',
          namespace: '*',
        );
        final XmlAttribute? resourceAttribute = metadata.getAttributeNode(
          'resource',
          namespace: '*',
        );
        if (resourceAttribute != null) {
          metadata.attributes.remove(resourceAttribute);
          changed = true;
        }
        if (valueAttribute == null) {
          metadata.attributes.add(
            XmlAttribute(XmlName('value', 'android'), value),
          );
          changed = true;
        } else if (valueAttribute.value != value) {
          valueAttribute.value = value;
          changed = true;
        }
        for (final XmlElement duplicate in matching.skip(1)) {
          application.children.remove(duplicate);
          changed = true;
        }
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
    final XmlDocument document;
    if (file.existsSync()) {
      document = _parseXmlFile(file, 'Android resource values XML');
    } else {
      document = XmlDocument.parse('<resources/>');
    }
    if (document.rootElement.name.local != 'resources') {
      throw StateError(
        'Android values XML root must be <resources>: ${file.path}',
      );
    }
    final XmlElement resources = document.rootElement;
    bool changed = false;
    for (final MapEntry<String, String> entry in credentials.entries) {
      final String name = _resourceName(entry.key);
      final List<XmlElement> matching =
          resources
              .findElements('string')
              .where((XmlElement child) => child.getAttribute('name') == name)
              .toList();
      if (matching.isEmpty) {
        resources.children.add(
          XmlElement(
            XmlName('string'),
            <XmlAttribute>[XmlAttribute(XmlName('name'), name)],
            <XmlNode>[XmlText(entry.value)],
          ),
        );
        changed = true;
      } else {
        final XmlElement node = matching.first;
        if (node.innerText != entry.value) {
          node.children.clear();
          node.children.add(XmlText(entry.value));
          changed = true;
        }
        for (final XmlElement duplicate in matching.skip(1)) {
          resources.children.remove(duplicate);
          changed = true;
        }
      }
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  String _resourceName(String key) =>
      'push_kit_${key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';

  bool _configureInfoPlist(File file, {required bool write}) {
    final XmlDocument document = _parseXmlFile(file, 'Info.plist');
    final XmlElement dict = _plistDict(document, file);
    final XmlElement? existing = _plistValue(dict, 'UIBackgroundModes');
    final XmlElement array;
    bool changed = false;
    if (existing == null) {
      array = XmlElement(XmlName('array'));
      _plistAppend(dict, 'UIBackgroundModes', array);
      changed = true;
    } else if (existing.name.local == 'array') {
      array = existing;
    } else {
      array = XmlElement(XmlName('array'));
      final int index = dict.children.indexOf(existing);
      if (index < 0) {
        throw StateError('Malformed UIBackgroundModes entry: ${file.path}');
      }
      dict.children[index] = array;
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

  bool _configureEntitlements(
    File file, {
    required String? environment,
    required bool write,
  }) {
    final XmlDocument document =
        file.existsSync()
            ? _parseXmlFile(file, 'iOS entitlements')
            : XmlDocument.parse(
              '<?xml version="1.0"?><plist version="1.0"><dict/></plist>',
            );
    final XmlElement dict = _plistDict(document, file);
    final XmlElement? existing = _plistValue(dict, 'aps-environment');
    bool changed = false;
    if (existing == null) {
      _plistAppend(
        dict,
        'aps-environment',
        XmlElement(XmlName('string'), <XmlAttribute>[], <XmlNode>[
          XmlText(environment ?? 'development'),
        ]),
      );
      changed = true;
    } else if (environment != null &&
        (existing.name.local != 'string' ||
            existing.innerText != environment)) {
      final int index = dict.children.indexOf(existing);
      if (index < 0) {
        throw StateError('Malformed aps-environment entry: ${file.path}');
      }
      dict.children[index] = XmlElement(
        XmlName('string'),
        <XmlAttribute>[],
        <XmlNode>[XmlText(environment)],
      );
      changed = true;
    }
    if (changed && write) _writeXml(file, document);
    return changed;
  }

  XmlDocument _parseXmlFile(File file, String description) {
    if (!file.existsSync()) {
      throw StateError('$description not found: ${file.path}');
    }
    try {
      return XmlDocument.parse(file.readAsStringSync());
    } on Object catch (error) {
      throw StateError('$description is malformed at ${file.path}: $error');
    }
  }

  XmlElement? _plistValue(XmlElement dict, String key) {
    final List<XmlElement> children = dict.childElements.toList();
    for (int index = 0; index + 1 < children.length; index++) {
      if (children[index].name.local == 'key' &&
          children[index].innerText == key) {
        return children[index + 1];
      }
    }
    return null;
  }

  XmlElement _plistDict(XmlDocument document, File file) {
    final XmlElement root = document.rootElement;
    if (root.name.local != 'plist') {
      throw StateError('Property list root must be <plist>: ${file.path}');
    }
    final List<XmlElement> dictionaries =
        root.childElements
            .where((XmlElement element) => element.name.local == 'dict')
            .toList();
    if (dictionaries.isEmpty) {
      throw StateError(
        'Property list does not contain a root <dict>: ${file.path}',
      );
    }
    final XmlElement dictionary = dictionaries.first;
    final List<XmlElement> children = dictionary.childElements.toList();
    for (int index = 0; index < children.length; index += 2) {
      if (index + 1 >= children.length || children[index].name.local != 'key') {
        throw StateError('Malformed plist dictionary: ${file.path}');
      }
    }
    return dictionary;
  }

  void _plistAppend(XmlElement dict, String key, XmlElement value) {
    dict.children.add(
      XmlElement(XmlName('key'), <XmlAttribute>[], <XmlNode>[XmlText(key)]),
    );
    dict.children.add(value);
  }

  String _relativeToIos(Directory root, File file) {
    final String basePath = Directory('${root.path}/ios').absolute.path;
    final String targetPath = file.absolute.path;
    final List<String> base = _pathParts(basePath);
    final List<String> target = _pathParts(targetPath);
    int common = 0;
    final bool insensitive = Platform.isWindows;
    while (common < base.length && common < target.length) {
      final String left =
          insensitive ? base[common].toLowerCase() : base[common];
      final String right =
          insensitive ? target[common].toLowerCase() : target[common];
      if (left != right) break;
      common++;
    }
    if (common == 0 && base.isNotEmpty && target.isNotEmpty) {
      throw StateError(
        'Entitlements path is on a different volume: ${file.path}',
      );
    }
    final List<String> relative = <String>[
      for (int index = common; index < base.length; index++) '..',
      ...target.skip(common),
    ];
    return relative.isEmpty ? target.last : relative.join('/');
  }

  List<String> _pathParts(String path) =>
      path
          .replaceAll('\\', '/')
          .split('/')
          .where((String part) => part.isNotEmpty)
          .toList();

  bool _configureXcodeProject(
    File file, {
    required String infoPlistPath,
    required String entitlementPath,
    required bool write,
  }) {
    if (!file.existsSync()) {
      throw StateError('Xcode project file not found: ${file.path}');
    }
    final String source = file.readAsStringSync();
    final bool crlf = source.contains('\r\n');
    final bool trailingNewline = source.endsWith('\n');
    final List<String> lines = source.split(RegExp(r'\r?\n'));
    if (trailingNewline && lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final List<String> updated = <String>[];
    bool changed = false;
    int matchedBlocks = 0;
    int index = 0;
    final RegExp start = RegExp(r'^\s*buildSettings\s*=\s*\{\s*$');
    final RegExp info = RegExp(
      r'^\s*INFOPLIST_FILE\s*=\s*(?:"([^"]*)"|([^;]+))\s*;\s*$',
    );
    final RegExp entitlements = RegExp(
      r'^(\s*)CODE_SIGN_ENTITLEMENTS\s*=\s*(?:"([^"]*)"|([^;]+))\s*;\s*$',
    );
    final String expectedInfoPlistPath = _normalizePbxPath(infoPlistPath);
    while (index < lines.length) {
      if (!start.hasMatch(lines[index])) {
        updated.add(lines[index++]);
        continue;
      }
      final List<String> block = <String>[lines[index]];
      int end = index + 1;
      while (end < lines.length && lines[end].trim() != '};') {
        block.add(lines[end++]);
      }
      if (end >= lines.length) {
        throw StateError('Unclosed buildSettings block in ${file.path}');
      }
      block.add(lines[end]);
      final int infoIndex = block.indexWhere(
        (String line) => info.hasMatch(line),
      );
      final RegExpMatch? infoMatch =
          infoIndex >= 0 ? info.firstMatch(block[infoIndex]) : null;
      final String actualInfoPlistPath =
          infoMatch == null
              ? ''
              : _normalizePbxPath(
                infoMatch.group(1) ?? infoMatch.group(2) ?? '',
              );
      if (actualInfoPlistPath == expectedInfoPlistPath) {
        matchedBlocks++;
        final List<int> existingEntitlements = <int>[];
        for (int lineIndex = 0; lineIndex < block.length; lineIndex++) {
          if (entitlements.hasMatch(block[lineIndex])) {
            existingEntitlements.add(lineIndex);
          }
        }
        final String indent = block[infoIndex].substring(
          0,
          block[infoIndex].length - block[infoIndex].trimLeft().length,
        );
        final String replacement =
            '$indent${_pbxKeyValue('CODE_SIGN_ENTITLEMENTS', entitlementPath)}';
        if (existingEntitlements.isEmpty) {
          block.insert(infoIndex + 1, replacement);
          changed = true;
        } else {
          final int firstEntitlement = existingEntitlements.first;
          if (block[firstEntitlement] != replacement) {
            block[firstEntitlement] = replacement;
            changed = true;
          }
          for (final int duplicate
              in existingEntitlements.skip(1).toList().reversed) {
            block.removeAt(duplicate);
            changed = true;
          }
        }
      }
      updated.addAll(block);
      index = end + 1;
    }
    if (matchedBlocks == 0) {
      throw StateError(
        'No Xcode build configuration for $infoPlistPath was found in ${file.path}',
      );
    }
    if (!changed) return false;
    final String separator = crlf ? '\r\n' : '\n';
    final String output =
        '${updated.join(separator)}${trailingNewline ? separator : ''}';
    if (write) file.writeAsStringSync(output);
    return true;
  }

  String _pbxKeyValue(String key, String value) {
    final String normalized = value.replaceAll('\\', '/');
    final bool needsQuotes = normalized.contains(RegExp(r'[\s"]'));
    final String encoded =
        needsQuotes ? '"${normalized.replaceAll('"', '\\"')}"' : normalized;
    return '$key = $encoded;';
  }

  String _normalizePbxPath(String path) {
    String normalized = path.trim().replaceAll('\\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    return normalized;
  }

  File _fileOrDefault(Directory root, File? input, String relative) =>
      input == null
          ? File('${root.path}/$relative')
          : _absoluteInputFile(root, input);

  File _absoluteInputFile(Directory root, File input) {
    final String path = input.path;
    final bool windowsAbsolute =
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
    final Uri uri = Uri.file(path);
    return windowsAbsolute || uri.isAbsolute
        ? input.absolute
        : File('${root.path}/$path');
  }

  String _clean(String? value) => value?.trim() ?? '';

  bool _isBlank(String? value) => value == null || value.trim().isEmpty;

  void _writeXml(File file, XmlDocument document) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${document.toXmlString(pretty: true, indent: '\t')}\n',
    );
  }

  bool _sameBytes(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (int index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class _FileSnapshot {
  const _FileSnapshot(this.file, this.bytes);

  final File file;
  final List<int>? bytes;
}
