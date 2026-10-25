import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protodesk_chat/protodesk_chat.dart';
import 'package:protodesk_chat_example/main.dart';
import 'package:protodesk_chat_example/host_identity.dart';
import '../../test/support/fake_transport.dart';

class Identity implements HostIdentity {
  bool connected = false, closed = false;
  int requests = 0;
  @override
  String get identityKey => 'host-account-42';
  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<String> freshToken() async => 'fresh-${++requests}';
  @override
  void close() {
    closed = true;
  }
}

Future<void> enter(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextField, label), value);
}

Future<void> open(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('offline doctor does not connect or echo invalid configuration', (
    tester,
  ) async {
    // Tall enough that results below the buttons are built.
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectScreen(
          initialize: (_) async {
            calls++;
            throw StateError('not expected');
          },
        ),
      ),
    );
    await enter(tester, 'API origin', 'https://user:SECRET@api.test');
    await open(tester, 'Check setup (offline)');
    expect(calls, 0);
    await tester.scrollUntilVisible(
      find.byType(SelectableText),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    final text = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(text, contains('failed'));
    expect(text, isNot(contains('SECRET')));
  });
  testWidgets('anonymous entry requests public configuration only', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectScreen()));
    expect(find.text('Public Chat App ID'), findsOneWidget);
    expect(find.text('Open anonymous chat'), findsOneWidget);
    expect(find.text('Host session access token'), findsNothing);
  });
  testWidgets('invalid configuration never initializes a session', (
    tester,
  ) async {
    // Tall enough that results below the buttons are built.
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ConnectScreen(
          initialize: (_) async {
            calls++;
            throw StateError('should not initialize');
          },
        ),
      ),
    );
    await enter(tester, 'API origin', 'http://insecure.test');
    await open(tester, 'Open anonymous chat');
    expect(calls, 0);
    expect(find.textContaining('Unable to connect.'), findsOneWidget);
  });
  testWidgets(
    'anonymous recovery options and explicit exit revoke the session',
    (tester) async {
      final t = FakeTransport();
      ChatClientOptions? options;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectScreen(
            initialize: (value) async {
              options = value;
              return makeClient(t);
            },
          ),
        ),
      );
      await enter(tester, 'Public Chat App ID', appId);
      await tester.tap(find.text('Create an identity if none is saved'));
      await open(tester, 'Open anonymous chat');
      expect(options!.identityTokenProvider, isNull);
      expect(options!.allowNewAnonymousIdentity, isTrue);
      // The messenger exits through its own Close button (from openChat).
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(
        t.calls.any(
          (call) =>
              call.method == 'DELETE' &&
              call.uri.path.endsWith('/sessions/current'),
        ),
        isTrue,
      );
    },
  );
  testWidgets(
    'verified host account supplies partition and fresh provider; exit clears host session',
    (tester) async {
      final identity = Identity();
      final t = FakeTransport();
      ChatClientOptions? options;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectScreen(
            verified: true,
            identityFactory: (uri, session) {
              expect(uri.toString(), 'https://host.test/chat-identity');
              expect(session, 'host-session');
              return identity;
            },
            initialize: (value) async {
              options = value;
              return makeClient(t);
            },
          ),
        ),
      );
      expect(find.text('Create an identity if none is saved'), findsNothing);
      await enter(
        tester,
        'Host identity endpoint (HTTPS)',
        'https://host.test/chat-identity',
      );
      await enter(tester, 'Host session access token', 'host-session');
      await enter(tester, 'Public Chat App ID', appId);
      await open(tester, 'Open verified chat');
      expect(identity.connected, isTrue);
      expect(options!.identityKey, 'host-account-42');
      expect(await options!.identityTokenProvider!(), 'fresh-1');
      expect(await options!.identityTokenProvider!(), 'fresh-2');
      expect(options!.allowNewAnonymousIdentity, isFalse);
      // The messenger exits through its own Close button (from openChat).
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(identity.closed, isTrue);
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Host session access token'),
      );
      expect(field.controller!.text, isEmpty);
    },
  );
}
