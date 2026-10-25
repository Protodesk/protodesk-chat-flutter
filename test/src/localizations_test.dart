import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

void main() {
  test(
    'English/Indonesian catalog, runtime states, overrides, and fallback',
    () {
      final en = ChatLocalizations(const Locale('en'));
      final id = ChatLocalizations(const Locale('id', 'ID'));
      final fallback = ChatLocalizations(const Locale('fr'));
      for (final key in ChatText.values) {
        expect(en.text(key), isNotEmpty);
        expect(id.text(key), isNotEmpty);
        expect(fallback.text(key), en.text(key));
      }
      for (final state in ChatUploadState.values) {
        expect(id.status(state.name), isNot(id.text(ChatText.unknownStatus)));
      }
      for (final state in ChatConnectionState.values) {
        expect(en.status(state.name), isNot(en.text(ChatText.unknownStatus)));
      }
      expect(id.number(12345), '12.345');
      expect(en.number(12345), '12,345');
      expect(id.error('secret.unrecognized'), isNot(contains('secret')));
      final custom = ChatLocalizations(
        const Locale('id'),
        overrides: {ChatText.send: 'Kirim pesan'},
      );
      expect(custom.text(ChatText.send), 'Kirim pesan');
      expect(custom.text(ChatText.close), 'Tutup');
      expect(
        en.format(ChatText.attachment, {'name': '{size}.txt', 'size': '10'}),
        '{size}.txt (10 bytes)',
      );
    },
  );
  test('brand themes preserve light/dark roles and custom typography', () {
    final light = ChatTheme.light(
      brandColor: Colors.orange,
      fontFamily: 'HostFont',
    );
    final dark = ChatTheme.dark(
      brandColor: Colors.orange,
      fontFamily: 'HostFont',
    );
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(light.textTheme.bodyMedium!.fontFamily, 'HostFont');
    expect(light.colorScheme.surface, isNot(dark.colorScheme.surface));
    // Fills use the brand itself; text uses a tone readable on each surface.
    expect(light.colorScheme.primary, Color(Colors.orange.toARGB32()));
    expect(dark.colorScheme.primary, Color(Colors.orange.toARGB32()));
    for (final theme in [light, dark]) {
      final text = ChatBrandColors.resolve(theme).foreground;
      final a = text.computeLuminance(),
          b = theme.colorScheme.surface.computeLuminance();
      final ratio =
          (a > b ? a + 0.05 : b + 0.05) / (a > b ? b + 0.05 : a + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5));
    }
  });

  test('Protodesk primary is the default brand, exactly', () {
    expect(ChatTheme.light().colorScheme.primary, const Color(0xff00a5d1));
    expect(ChatTheme.dark().colorScheme.primary, const Color(0xff00a5d1));
  });
}
