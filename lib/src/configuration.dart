import 'models.dart';

/// Server-controlled public Chat App configuration from `GET /v1/chat/bootstrap`.
/// Display and setup data only: none of it authorizes a request.
final class ChatAppConfiguration {
  ChatAppConfiguration._({
    required this.name,
    required this.appearance,
    required this.preChatForm,
    required this.helpCenter,
    required this.headerTitle,
    required this.greeting,
    required this.links,
    required this.routingChoices,
    required this.capabilities,
    required this.identity,
  });

  /// Throws `chat.invalid_response` when required fields are missing.
  /// Unsafe optional values (links, logo, colour) are dropped, not trusted.
  factory ChatAppConfiguration.fromBootstrap(Map<String, dynamic> json) {
    try {
      final configuration = json['configuration'] as Map;
      final widget = configuration['widget'] as Map;
      final name = (configuration['name'] as String).trim();
      if (name.isEmpty) throw const FormatException();
      return ChatAppConfiguration._(
        name: name,
        appearance: ChatAppearance._parse(configuration['appearance'] as Map),
        preChatForm: ChatPreChatForm._parse(configuration['preChatForm']),
        helpCenter: ChatHelpCenterSettings._parse(configuration['helpCenter']),
        headerTitle: _text(widget['headerTitle']) ?? name,
        greeting: _text(widget['greeting']) ?? '',
        links: List.unmodifiable([
          for (final link in widget['links'] as List? ?? const [])
            ?ChatWidgetLink._parse(link),
        ]),
        routingChoices: List.unmodifiable([
          for (final choice in widget['routingChoices'] as List? ?? const [])
            ?ChatRoutingChoice._parse(choice),
        ]),
        capabilities: ChatCapabilities._parse(json['capabilities'] as Map),
        identity: ChatEndUser._parse(json['identity'] as Map),
      );
    } on ProtodeskChatException {
      rethrow;
    } catch (_) {
      throw const ProtodeskChatException('chat.invalid_response');
    }
  }

  final String name, headerTitle, greeting;
  final ChatAppearance appearance;
  final ChatPreChatForm preChatForm;
  final ChatHelpCenterSettings helpCenter;
  final List<ChatWidgetLink> links;
  final List<ChatRoutingChoice> routingChoices;
  final ChatCapabilities capabilities;
  final ChatEndUser identity;

  /// Help is offered only when configured and content is currently available.
  bool get helpCenterAvailable => helpCenter.enabled && capabilities.helpCenter;

  /// A new conversation shows the setup step first (as the web widget does):
  /// an enabled pre-chat form, even one with only an intro, or routing choices.
  bool get requiresConversationSetup =>
      preChatForm.enabled || routingChoices.isNotEmpty;
}

enum ChatColorScheme { system, light, dark }

final class ChatAppearance {
  ChatAppearance._({
    required this.primaryColor,
    required this.logoUrl,
    required this.colorScheme,
    required this.showAgentAvatars,
  });
  factory ChatAppearance._parse(Map json) {
    final color = json['primaryColor'];
    return ChatAppearance._(
      primaryColor:
          color is String && RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(color)
          ? 0xff000000 | int.parse(color.substring(1), radix: 16)
          : null,
      logoUrl: safeHttpsUrl(json['logoUrl']),
      colorScheme: switch (json['preferredColorScheme']) {
        'light' => ChatColorScheme.light,
        'dark' => ChatColorScheme.dark,
        _ => ChatColorScheme.system,
      },
      showAgentAvatars: json['showAgentAvatars'] == true,
    );
  }

  /// ARGB brand colour, or null when the server value is invalid.
  final int? primaryColor;

  /// HTTPS logo without credentials; null shows the initial mark instead.
  final Uri? logoUrl;
  final ChatColorScheme colorScheme;
  final bool showAgentAvatars;
}

enum ChatPreChatFieldType { text, email, select, checkbox }

final class ChatPreChatForm {
  ChatPreChatForm._(this.enabled, this.intro, this.fields);
  factory ChatPreChatForm._parse(Object? value) {
    if (value is! Map) return ChatPreChatForm._(false, '', const []);
    final fields = [
      for (final field in value['fields'] as List? ?? const [])
        ?ChatPreChatField._parse(field),
    ];
    return ChatPreChatForm._(
      value['enabled'] == true,
      _text(value['intro']) ?? '',
      List.unmodifiable(fields),
    );
  }
  final bool enabled;
  final String intro;
  final List<ChatPreChatField> fields;
}

final class ChatPreChatField {
  ChatPreChatField._({
    required this.id,
    required this.type,
    required this.label,
    required this.required,
    required this.placeholder,
    required this.options,
  });

  /// Unknown field types are skipped so a newer server cannot break the form;
  /// the server still rejects a submission missing a required field.
  static ChatPreChatField? _parse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], label = _text(value['label']);
    final type = switch (value['type']) {
      'text' => ChatPreChatFieldType.text,
      'email' => ChatPreChatFieldType.email,
      'select' => ChatPreChatFieldType.select,
      'checkbox' => ChatPreChatFieldType.checkbox,
      _ => null,
    };
    final options = [
      for (final option in value['options'] as List? ?? const [])
        if (option is String && option.isNotEmpty) option,
    ];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id) ||
        label == null ||
        type == null ||
        (type == ChatPreChatFieldType.select && options.isEmpty)) {
      return null;
    }
    return ChatPreChatField._(
      id: id,
      type: type,
      label: label,
      required: value['required'] == true,
      placeholder: _text(value['placeholder']),
      options: List.unmodifiable(options),
    );
  }

  final String id, label;
  final ChatPreChatFieldType type;
  final bool required;
  final String? placeholder;
  final List<String> options;
}

final class ChatHelpCenterSettings {
  ChatHelpCenterSettings._(this.enabled, this.name, this.defaultLocale);
  factory ChatHelpCenterSettings._parse(Object? value) => value is Map
      ? ChatHelpCenterSettings._(
          value['enabled'] == true,
          _text(value['name']) ?? '',
          _text(value['defaultLocale']) ?? '',
        )
      : ChatHelpCenterSettings._(false, '', '');
  final bool enabled;
  final String name, defaultLocale;
}

final class ChatWidgetLink {
  ChatWidgetLink._(this.label, this.url);
  static ChatWidgetLink? _parse(Object? value) {
    if (value is! Map) return null;
    final label = _text(value['label']), url = safeHttpsUrl(value['url']);
    return label == null || url == null ? null : ChatWidgetLink._(label, url);
  }

  final String label;
  final Uri url;
}

final class ChatRoutingChoice {
  ChatRoutingChoice._(this.id, this.label);
  static ChatRoutingChoice? _parse(Object? value) {
    if (value is! Map) return null;
    final id = value['id'], label = _text(value['label']);
    return id is String &&
            RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id) &&
            label != null
        ? ChatRoutingChoice._(id, label)
        : null;
  }

  final String id, label;
}

/// Boolean capabilities a UI needs. Omitted values mean unavailable.
final class ChatCapabilities {
  ChatCapabilities._(Map json)
    : attachments = json['attachments'] == true,
      helpCenter = json['helpCenter'] == true,
      multipleConversations = json['multipleConversations'] == true,
      typing = json['typing'] == true,
      anonymousIdentityReset = json['anonymousIdentityReset'] == true,
      identityMerge = json['identityMerge'] == true;
  factory ChatCapabilities._parse(Map json) => ChatCapabilities._(json);
  final bool attachments,
      helpCenter,
      multipleConversations,
      typing,
      anonymousIdentityReset,
      identityMerge;
}

/// Customer-safe identity summary for greetings and avatars.
final class ChatEndUser {
  ChatEndUser._(this.kind, this.displayName, this.locale);
  factory ChatEndUser._parse(Map json) => ChatEndUser._(
    switch (json['kind']) {
      'anonymous' => ChatIdentityKind.anonymous,
      'verified' => ChatIdentityKind.verified,
      _ => throw const FormatException(),
    },
    _text(json['displayName']),
    _text(json['locale']),
  );
  final ChatIdentityKind kind;
  final String? displayName, locale;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// HTTPS URL with a host and no credentials, or null.
Uri? safeHttpsUrl(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
          uri.scheme == 'https' &&
          uri.host.isNotEmpty &&
          uri.userInfo.isEmpty
      ? uri
      : null;
}
