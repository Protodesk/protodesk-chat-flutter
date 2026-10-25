import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/src/version.dart';

void main() {
  test('reported SDK version matches pubspec and changelog', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version: (\S+)$', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(chatSdkVersion, version);
    expect(
      File('CHANGELOG.md').readAsLinesSync().first,
      '## $chatSdkVersion',
    );
  });
}
