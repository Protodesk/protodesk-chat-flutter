import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import 'attachments.dart';
import 'chat_screen.dart';
import 'client.dart';
import 'localizations.dart';
import 'models.dart';
import 'messenger_visibility.dart';

/// Convenience presentation bound to the receiving client, never global identity.
extension ChatPresentation on ProtodeskChatClient {
  /// Waits for initial session readiness, then pushes a Material route. Completes
  /// when that route is dismissed. Back navigation never logs out or disposes this
  /// client. The host owns identity changes and the client lifetime.
  ///
  /// Uses the nearest Navigator unless [useRootNavigator] is true. Reopening
  /// on the same navigator resumes the screen and
  /// unsent draft until the client changes identity or is disposed. An explicit
  /// conversation, article or start configuration opens that destination.
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
    ChatMessengerSection? initialSection,
    Future<void> Function(Uri url)? onOpenLink,
    String? initialHelpArticleId,
  }) async {
    await waitUntilReady();
    if (!context.mounted || state != ChatClientState.ready) {
      throw const ProtodeskChatException('chat.operation_cancelled');
    }
    final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
    final slots = (_presentations[this] ??= Expando())[navigator] ??=
        _Presentations();
    final help =
        initialSection == ChatMessengerSection.help ||
        initialHelpArticleId != null;
    final last = slots.last;
    var view = help ? slots.help : slots.chat;
    if (last != null && !last.expired && last.showingHelp == help) view = last;
    if (!help) view ??= last;
    final previous = view?.key.currentWidget as ChatScreen?;
    final targeted =
        (initialConversationId != null &&
            view?.location?.conversationId != initialConversationId) ||
        (initialHelpArticleId != null &&
            view?.location?.helpArticleId != initialHelpArticleId) ||
        (preChat.isNotEmpty && !mapEquals(preChat, previous?.preChat)) ||
        (routingChoiceId != null &&
            routingChoiceId != previous?.routingChoiceId) ||
        (initialSection != null &&
            !help &&
            initialSection != view?.requestedSection);
    if (view == null || view.expired || targeted) {
      // Explicit links replace their own entry point, not a draft reached
      // through another launcher.
      (help ? slots.help : slots.chat)?.forget();
      view = _RetainedView(this, initialSection);
      if (help) {
        slots.help = view;
      } else {
        slots.chat = view;
      }
    }
    slots.last = view;
    await view.open(
      navigator,
      routeSettings,
      (key, close) => ChatScreen(
        key: key,
        client: this,
        onClose: close,
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

// Each host navigator owns independent chat and Help entry points. Neither a
// BuildContext nor a draft is serialized; logout also removes parked subtrees.
final _presentations = Expando<Expando<_Presentations>>();

class _Presentations {
  _RetainedView? chat, help, last;
}

typedef _ScreenBuilder = Widget Function(Key key, VoidCallback close);

class _RetainedView {
  _RetainedView(ProtodeskChatClient client, this.requestedSection) {
    subscription = client.states.listen((state) {
      if (state != ChatClientState.ready) forget();
    });
  }
  final ChatMessengerSection? requestedSection;
  late final StreamSubscription<ChatClientState> subscription;
  final key = GlobalKey();
  final active = ValueNotifier<_MessengerRoute?>(null);
  OverlayEntry? parked;
  _ScreenBuilder? builder;
  bool expired = false;

  MessengerLocation? get location => key.currentState as MessengerLocation?;
  bool? get showingHelp => location?.showingHelp;

  Widget _screen(bool visible) => MessengerVisibility(
    visible: visible,
    child: builder!(key, () => active.value?.navigator?.pop()),
  );

  Future<void> open(
    NavigatorState navigator,
    RouteSettings? settings,
    _ScreenBuilder build,
  ) {
    final current = active.value;
    if (current != null) return current.popped;
    builder = build;
    final route = _MessengerRoute(view: this, settings: settings);
    active.value = route;
    _removeParked();
    return navigator.push<void>(route);
  }

  // Move the same element into an inert overlay in the pop frame. In-flight
  // sends and attachment uploads finish on the original draft; its controllers,
  // focus selection, scroll positions and nested Help history stay intact.
  void hide(_MessengerRoute route) {
    if (active.value != route) return;
    active.value = null;
    final overlay = route.navigator?.overlay;
    if (expired || overlay == null || !overlay.mounted) {
      builder = null;
      return;
    }
    final entry = OverlayEntry(
      maintainState: true,
      builder: (_) => Offstage(
        child: TickerMode(
          enabled: false,
          child: ExcludeFocus(child: _screen(false)),
        ),
      ),
    );
    parked = entry;
    // A nested host Navigator can disappear while the client remains alive.
    // Its overlay no longer owns a restorable widget in that case.
    entry.addListener(() {
      if (!entry.mounted) {
        scheduleMicrotask(() {
          if (identical(parked, entry)) forget();
        });
      }
    });
    overlay.insert(entry);
  }

  void _removeParked() {
    final entry = parked;
    parked = null;
    if (entry != null) {
      entry.remove();
      entry.dispose();
    }
  }

  void forget() {
    expired = true;
    unawaited(subscription.cancel());
    _removeParked();
    if (active.value == null) builder = null;
  }
}

/// A wide messenger leaves the host visible around the floating panel.
class _MessengerRoute extends PageRoute<void>
    with MaterialRouteTransitionMixin<void> {
  _MessengerRoute({required this.view, super.settings});
  final _RetainedView view;
  @override
  Widget buildContent(BuildContext context) => ValueListenableBuilder(
    valueListenable: view.active,
    builder: (_, current, _) =>
        identical(current, this) ? view._screen(true) : const SizedBox.shrink(),
  );
  @override
  bool didPop(void result) {
    final popped = super.didPop(result);
    if (popped) view.hide(this);
    return popped;
  }

  @override
  void dispose() {
    // A navigator may remove a route without popping it.
    if (identical(view.active.value, this)) {
      view.active.value = null;
      view.forget();
    }
    super.dispose();
  }

  @override
  bool get maintainState => true;
  @override
  bool get opaque => false;
}
