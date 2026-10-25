part of 'chat_screen.dart';

enum _ContactView { loading, hidden, form, saving, saved, loadFailed }

/// Optional follow-up email for anonymous visitors, shown inline after their
/// first saved message. Never blocks chatting and never verifies identity.
class _ContactPrompt extends StatefulWidget {
  const _ContactPrompt({
    super.key,
    required this.client,
    required this.conversationId,
    required this.strings,
  });
  final ProtodeskChatClient client;
  final String conversationId;
  final ChatLocalizations strings;

  @override
  State<_ContactPrompt> createState() => _ContactPromptState();
}

class _ContactPromptState extends State<_ContactPrompt> {
  final _email = TextEditingController();
  final _emailFocus = FocusNode();
  final _confirmationFocus = FocusNode();
  var _view = _ContactView.loading;
  bool _invalid = false, _failed = false, _sharedEmail = false;
  // One key per payload: an uncertain save is retried with the same key.
  String? _pendingPayload, _pendingKey;

  String _text(ChatText key) => widget.strings.text(key);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _view = _ContactView.loading);
    try {
      final contact = await widget.client.getContact(widget.conversationId);
      if (!mounted) return;
      setState(
        () => _view = contact.canRequest
            ? _ContactView.form
            : _ContactView.hidden,
      );
    } on ProtodeskChatException catch (error) {
      if (!mounted) return;
      // Older servers or verified sessions: the prompt simply does not apply.
      final unavailable = error.status == 403 || error.status == 404;
      setState(
        () =>
            _view = unavailable ? _ContactView.hidden : _ContactView.loadFailed,
      );
    } catch (_) {
      if (mounted) setState(() => _view = _ContactView.loadFailed);
    }
  }

  Future<void> _submit({required bool dismiss}) async {
    if (_view == _ContactView.saving) return;
    final email = _email.text.trim();
    final payload = dismiss ? 'dismiss' : 'email:$email';
    if (_pendingPayload != payload) {
      _pendingPayload = payload;
      _pendingKey = ProtodeskChatClient.newOperationId();
    }
    setState(() {
      _view = _ContactView.saving;
      _invalid = false;
      _failed = false;
    });
    try {
      final contact = dismiss
          ? await widget.client.dismissContactRequest(
              conversationId: widget.conversationId,
              operationId: _pendingKey!,
            )
          : await widget.client.shareContactEmail(
              conversationId: widget.conversationId,
              email: email,
              operationId: _pendingKey!,
            );
      if (!mounted) return;
      _pendingPayload = _pendingKey = null;
      setState(() {
        _sharedEmail = contact.hasEmail;
        _view = contact.canRequest ? _ContactView.form : _ContactView.saved;
      });
      if (_view == _ContactView.saved) _confirmationFocus.requestFocus();
    } on ProtodeskChatException catch (error) {
      if (!mounted) return;
      final status = error.status;
      // Definitive rejections start a new attempt; uncertain ones keep the key.
      if (status == null ||
          (status >= 400 && status < 500 && status != 408 && status != 429)) {
        _pendingPayload = _pendingKey = null;
      }
      setState(() {
        _view = _ContactView.form;
        _invalid = error.code == 'chat.contact_invalid';
        _failed = !_invalid;
      });
      _emailFocus.requestFocus();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _view = _ContactView.form;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _emailFocus.dispose();
    _confirmationFocus.dispose();
    super.dispose();
  }

  Widget _panel(ThemeData theme, Widget child) => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: child,
  );

  Widget _form(ThemeData theme) {
    final saving = _view == _ContactView.saving;
    return _panel(
      theme,
      Semantics(
        container: true,
        explicitChildNodes: true,
        label: _text(ChatText.contactRegion),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                _text(ChatText.contactTitle),
                style: theme.textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _text(ChatText.contactBody),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              focusNode: _emailFocus,
              enabled: !saving,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              inputFormatters: [LengthLimitingTextInputFormatter(254)],
              onChanged: (_) {
                if (_invalid || _failed) {
                  setState(() => _invalid = _failed = false);
                }
              },
              onSubmitted: (_) => unawaited(_submit(dismiss: false)),
              decoration: InputDecoration(
                labelText: _text(ChatText.contactEmail),
                errorText: _invalid ? _text(ChatText.contactInvalid) : null,
              ),
            ),
            if (_failed) ...[
              const SizedBox(height: 8),
              _ChatStatus(
                _text(ChatText.contactFailed),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => unawaited(_submit(dismiss: true)),
                  child: Text(_text(ChatText.contactDismiss)),
                ),
                FilledButton.tonal(
                  onPressed: saving
                      ? null
                      : () => unawaited(_submit(dismiss: false)),
                  child: Text(
                    _text(
                      saving && _pendingPayload != 'dismiss'
                          ? ChatText.contactSharing
                          : ChatText.contactShare,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(ThemeData theme) => switch (_view) {
    _ContactView.loading ||
    _ContactView.hidden => const SizedBox(width: double.infinity),
    _ContactView.form || _ContactView.saving => _form(theme),
    _ContactView.saved => Focus(
      focusNode: _confirmationFocus,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            Icon(
              Icons.check_circle_outline_rounded,
              size: MediaQuery.textScalerOf(context).scale(18),
              color: ChatBrandColors.resolve(theme).foreground,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ChatStatus(
                _text(
                  _sharedEmail
                      ? ChatText.contactShared
                      : ChatText.contactDismissed,
                ),
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    ),
    _ContactView.loadFailed => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          _ChatStatus(
            _text(ChatText.contactLoadFailed),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_load()),
            child: Text(_text(ChatText.contactRetry)),
          ),
        ],
      ),
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeOutCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, if (current != null) current],
      ),
      child: KeyedSubtree(
        key: ValueKey(_view == _ContactView.saving ? _ContactView.form : _view),
        child: _content(theme),
      ),
    );
  }
}
