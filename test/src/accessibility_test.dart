import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';

import '../support/fake_transport.dart';

Widget host(
  ProtodeskChatClient c, {
  double scale = 1,
  bool dark = false,
  double keyboard = 0,
  bool reduceMotion = false,
  bool initial = true,
  TargetPlatform platform = TargetPlatform.android,
  bool announce = false,
}) => MaterialApp(
  locale: const Locale('id'),
  supportedLocales: ChatLocalizations.supportedLocales,
  localizationsDelegates: ChatLocalizations.localizationsDelegates,
  theme: (dark ? ChatTheme.dark() : ChatTheme.light()).copyWith(
    platform: platform,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(scale),
      viewInsets: EdgeInsets.only(bottom: keyboard),
      disableAnimations: reduceMotion,
      supportsAnnounce: announce,
    ),
    child: child!,
  ),
  home: ChatScreen(
    client: c,
    initialConversationId: initial ? 'conv_test' : null,
    attachmentPicker: () async => null,
  ),
);
void main() {
  for (final scale in [1.0, 2.0, 3.0]) {
    for (final size in [const Size(320, 740), const Size(740, 320)]) {
      testWidgets('Indonesian scale $scale at $size reflows with keyboard', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(size);
        final t = FakeTransport();
        t.messages.add({
          ...message(
            text: 'Pesan panjang untuk memeriksa tampilan percakapan.',
          ),
          'sender': 'agent',
        });
        final c = await makeClient(t);
        await tester.pumpWidget(
          host(
            c,
            scale: scale,
            dark: scale == 3,
            keyboard: size.height > 500 ? 220 : 0,
            reduceMotion: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byType(TextField));
        await tester.enterText(
          find.byType(TextField),
          'Draf tetap dapat diedit',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('Kirim'));
        expect(
          tester.getRect(find.byTooltip('Kirim')).overlaps(Offset.zero & size),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        await c.dispose();
        await tester.binding.setSurfaceSize(null);
      });
    }
  }
  testWidgets(
    'labeled actions, live status, heading and native target guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final c = await makeClient(FakeTransport());
      await tester.pumpWidget(host(c));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.text('Bantuan')).flagsCollection.isHeader,
        isTrue,
      );
      expect(
        tester
            .getSemantics(find.text('Menghubungkan…'))
            .flagsCollection
            .isLiveRegion,
        isTrue,
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.pumpWidget(const SizedBox());
      await c.dispose();
      semantics.dispose();
    },
  );
  testWidgets(
    'keyboard can reach and activate conversation without a pointer',
    (tester) async {
      final c = await makeClient(FakeTransport());
      await tester.pumpWidget(host(c, initial: false));
      await tester.pumpAndSettle();
      var reached = false;
      for (var i = 0; i < 10; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focus = FocusManager.instance.primaryFocus;
        final widgetContext = focus?.context;
        if (widgetContext != null && _withinConversation(widgetContext)) {
          reached = true;
          break;
        }
      }
      expect(reached, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await c.dispose();
    },
  );
  testWidgets(
    'iOS announces changed status once, suppresses repeats and cancels on disposal',
    (tester) async {
      final announcements = <Object?>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(SystemChannels.accessibility, (
            message,
          ) async {
            announcements.add(message);
            return null;
          });
      final t = FakeTransport();
      final c = await makeClient(t);
      await tester.pumpWidget(
        host(c, platform: TargetPlatform.iOS, announce: true),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      announcements.clear();
      await c.disconnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        announcements.where((e) => e.toString().contains('Luring')).length,
        1,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(
        announcements.where((e) => e.toString().contains('Luring')).length,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      await c.dispose();
      await tester.pump(const Duration(seconds: 1));
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility,
            null,
          );
    },
  );
  test('default theme text and control role pairs meet AA contrast', () {
    double ratio(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return (math.max(x, y) + .05) / (math.min(x, y) + .05);
    }

    for (final theme in [ChatTheme.light(), ChatTheme.dark()]) {
      final c = theme.colorScheme;
      for (final pair in [
        [c.onSurface, c.surface],
        [c.onPrimary, c.primary],
        [c.error, c.surface],
        [c.onSurfaceVariant, c.surface],
      ]) {
        expect(ratio(pair[0], pair[1]), greaterThanOrEqualTo(4.5));
      }
      expect(ratio(c.outline, c.surface), greaterThanOrEqualTo(3));
    }
  });
}

/// True when focus sits on the conversation card for `conv_test`.
bool _withinConversation(BuildContext context) {
  var found = false;
  context.visitAncestorElements((element) {
    found = element.widget.key == const ValueKey('conv_test');
    return !found;
  });
  return found;
}
