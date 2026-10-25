import 'fake_transport.dart';

/// A complete `/v1/chat/bootstrap` body with a public Chat App configuration.
Map<String, dynamic> bootstrap({
  Map<String, dynamic> widget = const {},
  Map<String, dynamic> appearance = const {},
  Map<String, dynamic>? preChatForm,
  bool help = true,
  String name = 'Protodesk',
  Map<String, dynamic> identity = const {
    'kind': 'anonymous',
    'displayName': null,
    'locale': 'id',
  },
}) => {
  'identity': identity,
  'configuration': {
    'publicChatAppId': appId,
    'name': name,
    'appearance': {
      'primaryColor': '#00A5D1',
      'preferredColorScheme': 'dark',
      'logoUrl': 'https://cdn.example.test/logo.png',
      'showAgentAvatars': true,
      ...appearance,
    },
    'preChatForm':
        preChatForm ?? {'enabled': false, 'intro': '', 'fields': const []},
    'helpCenter': {'enabled': help, 'name': 'Help', 'defaultLocale': 'en'},
    'widget': {
      'headerTitle': 'Chat with us',
      'greeting': 'Hi! How can we help you?',
      'launcherPosition': 'right',
      'links': [
        {'label': 'Status', 'url': 'https://status.example.test'},
        {'label': 'Unsafe', 'url': 'http://status.example.test'},
        {'label': 'Creds', 'url': 'https://user:pass@example.test'},
      ],
      'routingChoices': const [],
      'proactive': {'enabled': false, 'delaySeconds': 2, 'message': ''},
      ...widget,
    },
    'capabilities': const {},
  },
  'capabilities': {
    'attachments': true,
    'helpCenter': help,
    'multipleConversations': true,
    'typing': true,
  },
  'unreadCount': 2,
};
