part of 'chat_screen.dart';

/// Pre-chat form and routing choices shown before a new conversation, with
/// the web widget's validation (`pre-chat.ts`). The server revalidates
/// everything; these checks only give immediate, specific feedback.
class _ConversationSetup extends StatefulWidget {
  const _ConversationSetup({
    super.key,
    required this.config,
    required this.strings,
    required this.submitting,
    required this.onSubmit,
    this.status,
  });
  final ChatAppConfiguration config;
  final ChatLocalizations strings;
  final bool submitting;
  final String? status;
  final void Function(Map<String, Object> preChat, String? routingChoiceId)
  onSubmit;

  @override
  State<_ConversationSetup> createState() => _ConversationSetupState();
}

class _ConversationSetupState extends State<_ConversationSetup> {
  final _text = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};
  final _selected = <String, String?>{};
  final _checked = <String, bool>{};
  final _errors = <String, String>{};
  final _routingFocus = FocusNode();
  String? _routing, _routingError;

  List<ChatPreChatField> get _fields => widget.config.preChatForm.enabled
      ? widget.config.preChatForm.fields
      : const [];
  String _t(ChatText key) => widget.strings.text(key);

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    for (final node in _focus.values) {
      node.dispose();
    }
    _routingFocus.dispose();
    super.dispose();
  }

  TextEditingController _controller(String id) =>
      _text.putIfAbsent(id, TextEditingController.new);
  FocusNode _node(String id) => _focus.putIfAbsent(id, FocusNode.new);

  void _submit() {
    final errors = <String, String>{};
    final values = <String, Object>{};
    for (final field in _fields) {
      switch (field.type) {
        case ChatPreChatFieldType.checkbox:
          final checked = _checked[field.id] ?? false;
          if (field.required && !checked) {
            errors[field.id] = _t(ChatText.checkboxRequired);
          } else {
            values[field.id] = checked;
          }
        case ChatPreChatFieldType.select:
          final value = _selected[field.id];
          if (value == null) {
            if (field.required) errors[field.id] = _t(ChatText.fieldRequired);
          } else if (!field.options.contains(value)) {
            errors[field.id] = _t(ChatText.invalidOption);
          } else {
            values[field.id] = value;
          }
        case ChatPreChatFieldType.text || ChatPreChatFieldType.email:
          final value = _controller(field.id).text.trim();
          if (value.isEmpty) {
            if (field.required) errors[field.id] = _t(ChatText.fieldRequired);
          } else if (value.runes.length > 1024) {
            errors[field.id] = _t(ChatText.valueTooLong);
          } else if (field.type == ChatPreChatFieldType.email &&
              !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
            errors[field.id] = _t(ChatText.invalidEmail);
          } else {
            values[field.id] = value;
          }
      }
    }
    final choices = widget.config.routingChoices;
    final routingError = choices.isNotEmpty && _routing == null
        ? _t(ChatText.routingRequired)
        : null;
    setState(() {
      _errors
        ..clear()
        ..addAll(errors);
      _routingError = routingError;
    });
    if (errors.isNotEmpty) {
      final first = _fields.firstWhere((f) => errors.containsKey(f.id));
      _node(first.id).requestFocus();
      return;
    }
    if (routingError != null) {
      _routingFocus.requestFocus();
      return;
    }
    widget.onSubmit(values, _routing);
  }

  Widget _label(ChatPreChatField field, ThemeData theme) => Text.rich(
    TextSpan(
      text: field.label,
      children: [
        if (field.required)
          TextSpan(
            text: ' *',
            semanticsLabel: ', ${_t(ChatText.required)}',
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    ),
  );

  Widget _field(ChatPreChatField field, ThemeData theme) {
    final error = _errors[field.id];
    final enabled = !widget.submitting;
    switch (field.type) {
      case ChatPreChatFieldType.checkbox:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CheckboxListTile(
              focusNode: _node(field.id),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _checked[field.id] ?? false,
              onChanged: enabled
                  ? (value) => setState(() {
                      _checked[field.id] = value ?? false;
                      _errors.remove(field.id);
                    })
                  : null,
              title: _label(field, theme),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: _ChatStatus(
                  error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        );
      case ChatPreChatFieldType.select:
        return DropdownButtonFormField<String>(
          focusNode: _node(field.id),
          initialValue: _selected[field.id],
          isExpanded: true,
          hint: Text(_t(ChatText.chooseOption)),
          decoration: InputDecoration(
            label: _label(field, theme),
            errorText: error,
          ),
          items: [
            for (final option in field.options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: enabled
              ? (value) => setState(() {
                  _selected[field.id] = value;
                  _errors.remove(field.id);
                })
              : null,
        );
      case ChatPreChatFieldType.text || ChatPreChatFieldType.email:
        final email = field.type == ChatPreChatFieldType.email;
        final name = RegExp(
          r'^(name|full[._-]?name)$',
          caseSensitive: false,
        ).hasMatch(field.id);
        return TextField(
          controller: _controller(field.id),
          focusNode: _node(field.id),
          enabled: enabled,
          keyboardType: email ? TextInputType.emailAddress : TextInputType.text,
          autocorrect: !email,
          autofillHints: email
              ? const [AutofillHints.email]
              : name
              ? const [AutofillHints.name]
              : null,
          textInputAction: TextInputAction.next,
          inputFormatters: [LengthLimitingTextInputFormatter(1024)],
          onChanged: (_) {
            if (_errors.containsKey(field.id)) {
              setState(() => _errors.remove(field.id));
            }
          },
          decoration: InputDecoration(
            label: _label(field, theme),
            hintText: field.placeholder,
            errorText: error,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = widget.config;
    final intro = config.preChatForm.enabled ? config.preChatForm.intro : '';
    final choices = config.routingChoices;
    return ListView(
      key: const ValueKey('conversation-setup'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Semantics(
          header: true,
          child: Text(
            config.greeting.isEmpty ? _t(ChatText.setupTitle) : config.greeting,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (intro.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            intro,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (widget.status != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _ChatStatus(
              widget.status!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
        for (final field in _fields) ...[
          const SizedBox(height: 16),
          KeyedSubtree(
            key: ValueKey('pre-chat-${field.id}'),
            child: _field(field, theme),
          ),
        ],
        if (choices.isNotEmpty) ...[
          const SizedBox(height: 20),
          Semantics(
            header: true,
            child: Text(
              _t(ChatText.routingLegend),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Focus(
            focusNode: _routingFocus,
            child: RadioGroup<String>(
              groupValue: _routing,
              onChanged: (value) {
                if (widget.submitting) return;
                setState(() {
                  _routing = value;
                  _routingError = null;
                });
              },
              child: Column(
                children: [
                  for (final choice in choices)
                    RadioListTile<String>(
                      key: ValueKey('routing-${choice.id}'),
                      contentPadding: EdgeInsets.zero,
                      value: choice.id,
                      title: Text(choice.label),
                    ),
                ],
              ),
            ),
          ),
          if (_routingError != null)
            Padding(
              // Aligns with Material's field error text.
              padding: const EdgeInsets.only(left: 12),
              child: _ChatStatus(
                _routingError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: widget.submitting ? null : _submit,
          child: Text(
            _t(widget.submitting ? ChatText.starting : ChatText.continueLabel),
          ),
        ),
      ],
    );
  }
}
