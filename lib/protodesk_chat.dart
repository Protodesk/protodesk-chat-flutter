/// Native customer Chat client. No platform admin credentials belong here.
library;

export 'src/client.dart';
export 'src/models.dart';
export 'src/configuration.dart' hide safeHttpsUrl;
export 'src/help.dart' hide parseHelpArticlePage;
export 'src/help_markdown.dart' hide parseHelpInline;
export 'src/transport.dart' show ChatTransport, ChatResponse, ChatSocket;

export 'src/storage.dart';

export 'src/history_controller.dart';
export 'src/help_controller.dart';

export 'src/send_queue.dart'
    show ChatSendQueue, ChatSendQueueOptions, ChatQueuedMessage, ChatSendState;

export 'src/attachments.dart';
export 'src/attachment_storage.dart';
export 'src/unread_controller.dart';

export 'src/push.dart';

export 'src/push_navigation.dart';

export 'src/push_binding.dart';

export 'src/diagnostics.dart' hide buildChatCapabilityReport;

export 'src/lifecycle.dart' show ChatLifecycleEvent;
