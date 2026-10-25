import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'attachments.dart';
import 'chat_screen.dart';
import 'client.dart';
import 'localizations.dart';
import 'models.dart';

/// Convenience presentation bound to the receiving client, never global identity.
extension ChatPresentation on ProtodeskChatClient {
  /// Waits for initial session readiness, then pushes a Material route. Completes
  /// when that route is dismissed. Back navigation never logs out or disposes this
  /// client. The host owns identity changes and the client lifetime.
  ///
  /// Uses the nearest Navigator unless [useRootNavigator] is true. Each call
  /// creates a separate route; hosts should disable repeated launch gestures.
  Future<void> openChat(
    BuildContext context, {
    bool useRootNavigator = false,
    RouteSettings? routeSettings,
    String? initialConversationId,
    Map<String, dynamic> preChat = const {},
    String? routingChoiceId,
    ThemeData? theme,
    ChatLocalizations? localizations,
    ChatAttachmentPicker? attachmentPicker,
    Future<void> Function(ChatAttachment, Uint8List)? onOpenAttachment,
    bool automaticReadReporting = true,
    ChatMessengerSection initialSection = ChatMessengerSection.home,
    Future<void> Function(Uri url)? onOpenLink,
    String? initialHelpArticleId,
  }) async {
    await waitUntilReady();
    if (!context.mounted || state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
    await Navigator.of(context, rootNavigator: useRootNavigator).push<void>(
      MaterialPageRoute<void>(
        settings: routeSettings,
        builder: (routeContext) => ChatScreen(
          client: this,
          onClose: () => Navigator.of(routeContext).maybePop(),
          initialConversationId: initialConversationId,
          preChat: preChat,
          routingChoiceId: routingChoiceId,
          theme: theme,
          localizations: localizations,
          attachmentPicker: attachmentPicker,
          onOpenAttachment: onOpenAttachment,
          automaticReadReporting: automaticReadReporting,
          initialSection: initialSection,
          onOpenLink: onOpenLink,
          initialHelpArticleId: initialHelpArticleId,
        ),
      ),
    );
  }

  /// [openChat] on the Help tab. Falls back to Home when the Chat App has no
  /// published Help content.
  Future<void> openHelpCenter(
    BuildContext context, {
    bool useRootNavigator = false,
    RouteSettings? routeSettings,
    ThemeData? theme,
    ChatLocalizations? localizations,
    Future<void> Function(Uri url)? onOpenLink,
    ChatAttachmentPicker? attachmentPicker,
  }) => openChat(
    context,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    theme: theme,
    localizations: localizations,
    onOpenLink: onOpenLink,
    attachmentPicker: attachmentPicker,
    initialSection: ChatMessengerSection.help,
  );

  /// [openChat] on one published Help article, identified by the public
  /// article ID from the Help API. Back returns to the Help home.
  Future<void> openHelpCenterArticle(
    BuildContext context,
    String articleId, {
    bool useRootNavigator = false,
    RouteSettings? routeSettings,
    ThemeData? theme,
    ChatLocalizations? localizations,
    Future<void> Function(Uri url)? onOpenLink,
    ChatAttachmentPicker? attachmentPicker,
  }) {
    if (articleId.isEmpty || articleId.length > 128) {
      throw const ProtodeskChatException('chat.help_request_invalid');
    }
    return openChat(
      context,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      theme: theme,
      localizations: localizations,
      onOpenLink: onOpenLink,
      attachmentPicker: attachmentPicker,
      initialHelpArticleId: articleId,
    );
  }
}
