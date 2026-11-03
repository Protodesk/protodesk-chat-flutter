import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

/// The driver writes only the named screenshots from the Android fixture.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final folder = Directory(Platform.environment['CHAT_COMPARISON_DIR']!);
    await folder.create(recursive: true);
    for (final screen in [
      'chat',
      'messages',
      'home',
      'help',
      'collection',
      'article',
      'populated',
      'attachment',
      'staged',
      'dark',
    ]) {
      await File(
        '${folder.path}/android-$screen.png',
      ).writeAsBytes(base64Decode(data![screen] as String));
    }
  },
);
