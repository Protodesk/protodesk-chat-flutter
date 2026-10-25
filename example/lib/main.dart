import 'package:flutter/material.dart';
import 'attachment_picker.dart';
import 'host_identity.dart';
import 'package:protodesk_chat/protodesk_chat_ui.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runExample();

void runExample({bool verified = false}) => runApp(
  MaterialApp(
    theme: ChatTheme.light(),
    darkTheme: ChatTheme.dark(),
    localizationsDelegates: ChatLocalizations.localizationsDelegates,
    supportedLocales: ChatLocalizations.supportedLocales,
    home: ConnectScreen(verified: verified),
  ),
);

/// Both entry points share the native shell, attachment picker and lifecycle.
class ConnectScreen extends StatefulWidget {
  const ConnectScreen({
    super.key,
    this.verified = false,
    this.initialize = initializeChat,
    this.identityFactory = HttpHostIdentity.new,
  });
  final bool verified;
  final Future<ProtodeskChatClient> Function(ChatClientOptions) initialize;
  final HostIdentity Function(Uri, String) identityFactory;
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final _origin = TextEditingController(text: 'https://api.protodesk.io');
  final _app = TextEditingController();
  final _storageOrigin = TextEditingController();
  final _identityEndpoint = TextEditingController();
  final _hostSession = TextEditingController();
  bool _busy = false;
  bool _allowNew = false;
  bool _recoverLost = false;
  bool _persistAttachments = false;
  String? _error;
  ChatSetupReport? _setup;
  void _validateSetup() {
    setState(
      () => _setup = validateChatSetup(
        publicChatAppId: _app.text.trim(),
        apiOrigin: _origin.text.trim(),
        platform: Theme.of(context).platform == TargetPlatform.iOS
            ? 'ios'
            : 'android',
        verified: widget.verified,
        // Verified partition is established later by the authenticated host response.
        hasIdentityKey: false,
        storageConfigured: true,
        storageIsSecure: true,
        persistSendQueue: true,
        persistAttachments: _persistAttachments,
        attachmentOrigins: [
          if (_storageOrigin.text.trim().isNotEmpty) _storageOrigin.text.trim(),
        ],
      ),
    );
  }

  Future<void> _open({
    ChatMessengerSection section = ChatMessengerSection.home,
  }) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    ProtodeskChatClient? client;
    HostIdentity? identity;
    try {
      final origin = requireHttps(_origin.text.trim(), originOnly: true);
      if (_app.text.trim().isEmpty) throw const FormatException();
      if (widget.verified) {
        final endpoint = requireHttps(_identityEndpoint.text.trim());
        if (_hostSession.text.trim().isEmpty) throw const FormatException();
        identity = widget.identityFactory(endpoint, _hostSession.text.trim());
        _hostSession.clear();
        await identity.connect();
      }
      if (!mounted) return;
      client = await widget.initialize(
        ChatClientOptions(
          publicChatAppId: _app.text.trim(),
          identityKey: identity?.identityKey,
          identityTokenProvider: identity?.freshToken,
          storage: const PlatformChatStorage(),
          persistSendQueue: true,
          attachmentPersistence: _persistAttachments
              ? ChatAttachmentPersistencePolicy.managedPrivateCopy
              : ChatAttachmentPersistencePolicy.disabled,
          attachmentStorageOrigins: {
            if (_storageOrigin.text.trim().isNotEmpty)
              requireHttps(_storageOrigin.text.trim(), originOnly: true),
          },
          allowNewAnonymousIdentity: !widget.verified && _allowNew,
          recoverLostAnonymousIdentity: !widget.verified && _recoverLost,
          baseUrl: origin,
          platform: Theme.of(context).platform == TargetPlatform.iOS
              ? 'ios'
              : 'android',
        ),
      );
      if (!mounted) return;
      setState(() {
        _allowNew = false;
        _recoverLost = false;
      });
      // openChat pushes the messenger with a close button and completes when
      // it is dismissed; Help falls back to Home if the app has no Help.
      await client.openChat(
        context,
        initialSection: section,
        // Configured Chat App links and Help links are HTTPS; open them
        // outside the app.
        onOpenLink: (url) =>
            launchUrl(url, mode: LaunchMode.externalApplication),
        attachmentPicker: _storageOrigin.text.trim().isEmpty
            ? null
            : pickChatAttachment,
      );
      await client.logout();
    } catch (error) {
      if (mounted)
        setState(
          () => _error = error is ProtodeskChatException
              ? error.code
              : 'Unable to connect. Check public configuration and, for verified chat, your host session and identity endpoint.',
        );
    } finally {
      await client?.dispose();
      identity?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _identityEndpoint.dispose();
    _hostSession.dispose();
    _origin.dispose();
    _app.dispose();
    _storageOrigin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.verified ? 'Verified Chat example' : 'Anonymous Chat example',
      ),
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.verified) ...[
            const Text(
              'Use a short-lived host login session from your test backend. Never enter a Protodesk server key. The session is kept in memory only.',
            ),
            TextField(
              controller: _identityEndpoint,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Host identity endpoint (HTTPS)',
              ),
            ),
            TextField(
              controller: _hostSession,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Host session access token',
              ),
            ),
          ],
          TextField(
            controller: _origin,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'API origin'),
          ),
          TextField(
            controller: _app,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: 'Public Chat App ID'),
          ),
          TextField(
            controller: _storageOrigin,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Attachment storage origin (optional)',
            ),
          ),
          CheckboxListTile(
            title: const Text('Keep attachments securely for restart recovery'),
            subtitle: const Text(
              'Opt-in: private copies expire after 24 hours. Requires the storage origin.',
            ),
            value: _persistAttachments,
            onChanged: _busy
                ? null
                : (value) =>
                      setState(() => _persistAttachments = value ?? false),
          ),
          if (!widget.verified)
            CheckboxListTile(
              title: const Text('Create an identity if none is saved'),
              value: _allowNew,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _allowNew = value ?? false),
            ),
          if (!widget.verified)
            CheckboxListTile(
              title: const Text('Recover lost anonymous identity'),
              subtitle: const Text(
                'Starts fresh if old credentials are lost. Old history cannot be restored.',
              ),
              value: _recoverLost,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _recoverLost = value ?? false),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => _open(),
            child: Text(
              _busy
                  ? 'Connecting…'
                  : widget.verified
                  ? 'Open verified chat'
                  : 'Open anonymous chat',
            ),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _open(section: ChatMessengerSection.help),
            child: const Text('Open Help Center'),
          ),
          TextButton(
            onPressed: _busy ? null : _validateSetup,
            child: const Text('Check setup (offline)'),
          ),
          if (_setup != null) ...[
            const Text(
              'Unverified host/device checks remain unknown. Verified identity partition is checked after host sign-in.',
            ),
            SelectableText(_setup.toString()),
          ],
          if (_error != null) Text(_error!),
        ],
      ),
    ),
  );
}
