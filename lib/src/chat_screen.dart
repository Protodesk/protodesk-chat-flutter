import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'models.dart';
import 'messenger_visibility.dart';
import 'localizations.dart';
import 'theme.dart';
import 'launcher_button.dart';
import 'widget_icon.dart';
import 'history_controller.dart';
import 'unread_controller.dart';
import 'send_queue.dart';
import 'attachments.dart';
import 'configuration.dart';
import 'help.dart';
import 'help_controller.dart';
import 'help_markdown.dart';

part 'chat_screen_context.dart';
part 'messenger_parts.dart';
part 'help_view.dart';
part 'setup_view.dart';

/// Earlier name of [ChatMessenger]; kept so existing hosts keep compiling.
typedef ChatScreen = ChatMessenger;

/// Top-level messenger sections shown in the bottom navigation.
/// Help appears only when the Chat App has published Help content.
enum ChatMessengerSection { home, messages, help }

/// Livechat-style support messenger matching the Protodesk web widget.
/// The host owns the client and calls logout/dispose when appropriate.
class ChatMessenger extends StatefulWidget {
  const ChatMessenger({
    super.key,
    required this.client,
    this.preChat = const {},
    this.initialConversationId,
    this.theme,
    this.localizations,
    this.routingChoiceId,
    this.attachmentPicker,
    this.onOpenAttachment,
    this.automaticReadReporting = true,
    this.onClose,
    ChatMessengerSection? initialSection,
    this.onOpenLink,
    this.initialHelpArticleId,
  }) : initialSection = initialSection ?? ChatMessengerSection.messages,
       _resumeOnOpen =
           initialSection == null &&
           initialConversationId == null &&
           initialHelpArticleId == null;
  final bool _resumeOnOpen;
  final ProtodeskChatClient client;

  /// Overrides colours and fonts. Without it the Chat App's brand colour and
  /// colour scheme are used once loaded, otherwise the host Theme.
  final ThemeData? theme;

  /// Shows a close button that calls this (for example, popping the route).
  final VoidCallback? onClose;

  /// Explicit tab override. By default chat resumes the latest conversation
  /// or opens a new draft, as the website does.
  final ChatMessengerSection initialSection;

  /// Opens this published Help article first (its public article ID, never
  /// an internal one). Falls back to Home when Help is unavailable.
  final String? initialHelpArticleId;

  /// Opens the Chat App's configured HTTPS links (for example with
  /// `url_launcher`). Without it, Home does not list those links.
  final Future<void> Function(Uri url)? onOpenLink;

  /// Optional per-screen copy overrides. Otherwise follows host Localizations.
  final ChatLocalizations? localizations;

  /// Initial conversation selected by an authenticated push navigation callback.
  final String? initialConversationId;

  /// Report a canonical incoming message after its whole tile remains visible
  /// for one second at rest. Disable for host-controlled read semantics; each
  /// support message then offers an explicit "Mark read through here".
  final bool automaticReadReporting;
  final Map<String, dynamic> preChat;
  final String? routingChoiceId;
  final ChatAttachmentPicker? attachmentPicker;

  /// Host viewer for PDF/audio/video/text. Bytes are memory-only; do not log them.
  final Future<void> Function(ChatAttachment attachment, Uint8List bytes)?
  onOpenAttachment;
  @override
  State<ChatMessenger> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatMessenger>
    with WidgetsBindingObserver
    implements MessengerLocation {
  @override
  bool get showingHelp =>
      _selected == null &&
      !_newThread &&
      !_settingUp &&
      _visibleSection == ChatMessengerSection.help;

  @override
  String? get conversationId => _selected;
  @override
  String? get helpArticleId {
    final page = _helpPageKey.currentState;
    final route = page?._stack.last;
    return showingHelp && route is _HelpArticleRoute ? route.id : null;
  }

  ChatLocalizations get _strings =>
      widget.localizations ?? ChatLocalizations.of(context);
  ChatLocalizations get _helpStrings {
    final strings = _strings;
    final language = _help?.manifest?.activeLocale
        .split('-')
        .first
        .toLowerCase();
    return language == null || language == strings.locale.languageCode
        ? strings
        : ChatLocalizations(Locale(language), overrides: strings.overrides);
  }

  String _text(ChatText key) => _strings.text(key);
  ThemeData get _theme {
    final host = Theme.of(context);
    final theme =
        widget.theme ??
        _brandTheme ??
        (host.extension<ChatBrandColors>() != null
            ? host
            : (host.brightness == Brightness.dark
                      ? ChatTheme.dark()
                      : ChatTheme.light())
                  .copyWith(platform: host.platform));
    return MediaQuery.highContrastOf(context)
        ? ChatTheme.accessible(theme)
        : theme;
  }

  ChatAppConfiguration? _config;
  ThemeData? get _brandTheme {
    if (_config == null) return null;
    final color = Color(
      _config!.appearance.primaryColor ?? ChatTheme.protodeskPrimary.toARGB32(),
    );
    final dark = switch (_config!.appearance.colorScheme) {
      ChatColorScheme.light => false,
      ChatColorScheme.dark => true,
      ChatColorScheme.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    return dark
        ? ChatTheme.dark(brandColor: color)
        : ChatTheme.light(brandColor: color);
  }

  String get _appName => _config?.name ?? _text(ChatText.support);

  Future<void> _loadConfiguration() async {
    final epoch = _epoch;
    try {
      final config = await widget.client.getConfiguration();
      if (!mounted || epoch != _epoch) return;
      setState(() => _config = config);
      if (config.helpCenterAvailable) unawaited(_help?.load());
    } catch (_) {
      // Branding is optional: the messenger works with host defaults.
    }
  }

  final _draft = TextEditingController();
  final _homeSearch = TextEditingController();
  final _composerFocus = FocusNode();
  final _subscriptions = <StreamSubscription>[];
  List<ChatConversation> _conversations = [];
  List<ChatMessage> _messages = [];
  String? _selected, _error, _createId;
  late bool _resumeOnOpen = widget._resumeOnOpen;
  late ChatMessengerSection _section = widget.initialSection;

  /// The pre-chat step is open; [_setupStatus] explains a stale-form reload.
  bool _settingUp = false;
  String? _setupStatus;

  // Null until a visitor finishes setup (or enters an unconfigured draft).
  // No server conversation exists until they send or select an attachment.
  Map<String, dynamic>? _newPreChat;
  String? _newRouting;
  bool get _newThread => _newPreChat != null;
  bool _articleExpanded = false;

  void _compose(Map<String, dynamic> preChat, String? routing) {
    setState(() {
      _settingUp = false;
      _newPreChat = preChat;
      _newRouting = routing;
      _error = null;
    });
  }

  bool get _needsSetup =>
      _config?.requiresConversationSetup == true &&
      widget.preChat.isEmpty &&
      widget.routingChoiceId == null;

  /// Every "start a conversation" action goes through the setup step when the
  /// Chat App requires one and the host did not supply the values.
  void _startConversation() {
    if (_creating) return;
    _resumeOnOpen = false;
    _articleExpanded = false;
    if (_needsSetup) {
      setState(() {
        _settingUp = true;
        _setupStatus = null;
        _createId = null;
      });
    } else {
      _compose(widget.preChat, widget.routingChoiceId);
    }
  }

  // The open conversation when known (tapped or created); used for context.
  ChatConversation? _opened;
  bool _creating = false, _loading = true, _saving = false;
  int _epoch = 0;
  bool _picking = false, _previewing = false;
  bool _reportingRead = false;
  final _readViewport = GlobalKey();
  final _readTiles = <String, GlobalKey>{};
  final _visibleSince = <String, Duration>{};
  Duration get _readElapsed =>
      Duration(milliseconds: 100 * (_readTimer?.tick ?? 0));
  Timer? _readTimer;
  bool _scrollingMessages = false;
  int _readGeneration = 0;
  ChatMessage? _automaticReadBoundary;
  String? _automaticAttempt;

  void _resetReadViewport() {
    ++_readGeneration;
    _visibleSince.clear();
    _readTiles.clear();
    _automaticReadBoundary = null;
    _automaticAttempt = null;
    _reportingRead = false;
    _scrollingMessages = false;
  }

  bool get _canReadViewport =>
      mounted &&
      _visible &&
      widget.automaticReadReporting &&
      widget.client.state == ChatClientState.ready &&
      _selected != null &&
      !_loading &&
      !_picking &&
      !_previewing &&
      !_scrollingMessages &&
      TickerMode.valuesOf(context).enabled &&
      ModalRoute.of(context)?.isCurrent != false &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);

  bool _newerReadBoundary(ChatMessage message, ChatMessage previous) =>
      message.createdAt.isAfter(previous.createdAt) ||
      (message.createdAt == previous.createdAt &&
          message.id.compareTo(previous.id) > 0);

  void _sampleReadViewport() {
    if (!_canReadViewport) {
      _visibleSince.clear();
      _automaticAttempt = null;
      return;
    }
    final viewport = _readViewport.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      return;
    }
    RenderObject child = viewport;
    for (
      RenderObject? ancestor = viewport.parent;
      ancestor != null;
      ancestor = ancestor.parent
    ) {
      var hidden = ancestor is RenderOffstage && ancestor.offstage;
      if (ancestor is RenderIndexedStack) {
        final children = ancestor.getChildrenAsList();
        hidden = ancestor.index == null || children[ancestor.index!] != child;
      }
      if (hidden) {
        _visibleSince.clear();
        _automaticAttempt = null;
        return;
      }
      child = ancestor;
    }
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    final screenRect = Offset.zero & MediaQuery.sizeOf(context);
    var clip = viewportRect.intersect(screenRect);
    // Account for the outer scroll viewport used with a keyboard/short window.
    for (
      RenderObject? parent = viewport.parent;
      parent != null;
      parent = parent.parent
    ) {
      if (parent is RenderBox && parent.hasSize) {
        clip = clip.intersect(parent.localToGlobal(Offset.zero) & parent.size);
      }
    }
    final visible = <String>{};
    ChatMessage? candidate;
    for (final message in _messages) {
      if (message.sender == 'endUser' || !message.id.startsWith('msg_')) {
        continue;
      }
      final tile = _readTiles[message.id]?.currentContext?.findRenderObject();
      if (tile is! RenderBox ||
          !tile.attached ||
          !tile.hasSize ||
          tile.size.isEmpty) {
        continue;
      }
      final rect = tile.localToGlobal(Offset.zero) & tile.size;
      if (clip.isEmpty ||
          rect.left < clip.left ||
          rect.right > clip.right ||
          rect.top < clip.top ||
          rect.bottom > clip.bottom) {
        continue;
      }
      visible.add(message.id);
      final since = _visibleSince.putIfAbsent(message.id, () => _readElapsed);
      if (_readElapsed - since < const Duration(seconds: 1)) continue;
      if (_automaticReadBoundary != null &&
          !_newerReadBoundary(message, _automaticReadBoundary!)) {
        continue;
      }
      if (candidate == null || _newerReadBoundary(message, candidate)) {
        candidate = message;
      }
    }
    _visibleSince.removeWhere((id, _) => !visible.contains(id));
    _readTiles.removeWhere((_, key) => key.currentContext == null);
    if (candidate == null) {
      _automaticAttempt = null;
    } else if (!_reportingRead && _automaticAttempt != candidate.id) {
      _automaticAttempt = candidate.id;
      unawaited(_markRead(candidate));
    }
  }

  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = MessengerVisibility.of(context);
    if (_visible != visible) {
      _visible = visible;
      if (visible && widget.client.state == ChatClientState.ready) {
        _closePresentation = widget.client.trackChatPresentation();
        _watchReadViewport();
        unawaited(widget.client.connect());
        unawaited(_load());
      } else {
        _readTimer?.cancel();
        _readTimer = null;
        _closePresentation?.call();
        _closePresentation = null;
        if (_selected != null) widget.client.setTyping(_selected!, false);
        _composerFocus.unfocus();
        unawaited(widget.client.disconnect());
      }
    }
    // Route coverage, tab visibility and layout changes require a fresh dwell.
    _visibleSince.clear();
  }

  void Function()? _closePreview;
  String? _attachmentSendId;
  final _uploads = <ChatAttachmentUpload>[];
  void _clearAttachments({bool discard = false}) {
    _closePreview?.call();
    _closePreview = null;
    _attachmentSendId = null;
    _picking = false;
    _previewing = false;
    if (discard || !widget.client.attachments.isPersistent) {
      for (final upload in _uploads.toList()) {
        unawaited(_queueAction(() => widget.client.attachments.cancel(upload)));
      }
    }
    _uploads.clear();
  }

  ChatAttachments? _attachmentManager;
  StreamSubscription<void>? _attachmentSubscription;
  void _bindAttachments() {
    final manager = widget.client.attachments;
    if (identical(manager, _attachmentManager)) return;
    unawaited(_attachmentSubscription?.cancel());
    _attachmentManager = manager;
    _attachmentSubscription = manager.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        if (manager.isPersistent) _syncAttachments();
        _error = manager.storageError?.code ?? _error;
      });
    });
  }

  void _syncAttachments() {
    final manager = widget.client.attachments;
    if (!manager.isPersistent) return;
    _uploads
      ..clear()
      ..addAll(_selected == null ? [] : manager.pendingUploads(_selected!));
    final draft = manager.pendingDrafts
        .where((d) => d.conversationId == _selected)
        .firstOrNull;
    _attachmentSendId = draft?.id;
    if (draft != null) _draft.text = draft.text;
  }

  void Function()? _closePresentation;
  ChatUnreadController? _unread;
  ChatHelpController? _help;

  /// Where Home asked Help to open; a new generation rebuilds the section.
  _HelpRoute _helpEntry = const _HelpRoot();
  var _helpPageKey = GlobalKey<_HelpSectionState>();

  bool get _helpAvailable =>
      _config?.helpCenterAvailable == true &&
      _help != null &&
      !_help!.isUnavailable;

  /// Help stays visible while configuration loads (no Home flash when opened
  /// on Help); it falls back to Home once Help is known to be unavailable.
  ChatMessengerSection get _visibleSection {
    if (_section != ChatMessengerSection.help) return _section;
    final unavailable = _config == null
        ? _help?.isUnavailable ?? true
        : !_helpAvailable;
    return unavailable ? ChatMessengerSection.home : _section;
  }

  void _openHelp(_HelpRoute entry) {
    _resumeOnOpen = false;
    setState(() {
      _helpEntry = entry;
      _helpPageKey = GlobalKey<_HelpSectionState>();
      _section = ChatMessengerSection.help;
    });
  }

  ChatHistoryController? _history;
  StreamSubscription<void>? _historySubscription;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialConversationId;
    WidgetsBinding.instance.addObserver(this);
    _composerFocus.addListener(() {
      if (!_composerFocus.hasFocus && _selected != null) {
        widget.client.setTyping(_selected!, false);
      }
    });
    _watchReadViewport();
    _bind();
    final article = widget.initialHelpArticleId;
    if (article != null && article.isNotEmpty && _selected == null) {
      _section = ChatMessengerSection.help;
      _helpEntry = _HelpArticleRoute(article, '', _help!.article(article));
    }
  }

  void _watchReadViewport() {
    _readTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _sampleReadViewport(),
    );
  }

  void _bind() {
    final client = widget.client;
    _closePresentation = client.trackChatPresentation();
    _unread = ChatUnreadController(client);
    _help = ChatHelpController(client);
    _subscriptions.add(
      _help!.changes.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subscriptions.add(
      _unread!.changes.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subscriptions.add(
      client.typingChanges.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _bindAttachments();
    _subscriptions.add(
      client.connectionStates.listen((_) {
        if (mounted) setState(() {});
      }),
    );
    _subscriptions.add(
      client.errors.listen((error) {
        if (mounted) setState(() => _error = error.code);
      }),
    );
    _subscriptions.add(
      client.states.listen((state) {
        if (!mounted) return;
        if (state != ChatClientState.ready) {
          ++_epoch;
          _releaseHistory();
          _reportingRead = false;
          _draft.clear();
          _homeSearch.clear();
          _helpEntry = const _HelpRoot();
          _helpPageKey = GlobalKey<_HelpSectionState>();
          _opened = null;
          _newRouting = null;
          _clearAttachments();
          setState(() {
            _config = null;
            _newPreChat = null;
            _articleExpanded = false;
            _settingUp = false;
            _saving = false;
            _resumeOnOpen = widget._resumeOnOpen;
            _setupStatus = null;
            _conversations = [];
            _messages = [];
            _selected = null;
            _createId = null;
            _creating = false;
            _loading = false;
            _error = null;
          });
        } else if (_visible) {
          unawaited(_load());
          unawaited(client.connect());
        }
      }),
    );
    unawaited(_load());
    if (client.state == ChatClientState.ready) unawaited(client.connect());
  }

  @override
  void didUpdateWidget(covariant ChatMessenger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _closePresentation?.call();
      _closePreview?.call();
      _closePreview = null;
      for (final subscription in _subscriptions) {
        unawaited(subscription.cancel());
      }
      _subscriptions.clear();
      unawaited(_unread?.dispose());
      unawaited(_help?.dispose());
      if (!oldWidget.client.attachments.isPersistent) {
        for (final upload in _uploads) {
          unawaited(
            oldWidget.client.attachments
                .cancel(upload)
                .catchError((Object _) {}),
          );
        }
      }
      _uploads.clear();
      _attachmentSendId = null;
      _picking = false;
      unawaited(oldWidget.client.disconnect());
      ++_epoch;
      _releaseHistory();
      _draft.clear();
      _config = null;
      _homeSearch.clear();
      _helpEntry = const _HelpRoot();
      _helpPageKey = GlobalKey<_HelpSectionState>();
      _opened = null;
      _newRouting = null;
      _section = widget.initialSection;
      _settingUp = false;
      _newPreChat = null;
      _saving = false;
      _resumeOnOpen = widget._resumeOnOpen;
      _articleExpanded = false;
      _conversations = [];
      _messages = [];
      _selected = widget.initialConversationId;
      _reportingRead = false;
      _createId = null;
      _creating = false;
      _loading = true;
      _error = null;
      _bind();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visibleSince.clear();
    if (!_visible) return;
    if (state == AppLifecycleState.resumed &&
        widget.client.state == ChatClientState.ready) {
      unawaited(widget.client.connect());
      unawaited(_load());
    } else {
      widget.client.attachments.suspend();
      unawaited(widget.client.disconnect());
    }
  }

  void _releaseHistory() {
    _resetReadViewport();
    unawaited(_historySubscription?.cancel());
    unawaited(_history?.dispose());
    _historySubscription = null;
    _history = null;
  }

  Future<void> _load() async {
    if (widget.client.state != ChatClientState.ready) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    unawaited(_unread?.refresh());
    final configuration = _config == null ? _loadConfiguration() : null;
    _bindAttachments();
    _syncAttachments();
    if (_history == null || _history!.conversationId != _selected) {
      _releaseHistory();
      final history = ChatHistoryController(
        widget.client,
        conversationId: _selected,
      );
      _history = history;
      _historySubscription = history.changes.listen((_) {
        if (!mounted || !identical(_history, history)) return;
        setState(() {
          if (_selected == null) {
            _conversations = history.conversations;
          } else {
            _messages = history.messages;
          }
          _loading = history.isLoading;
          _error =
              history.error?.code ?? widget.client.sendQueue.lastError?.code;
        });
      });
    }
    final selected = _selected;
    if (selected != null && _openConversation == null) {
      unawaited(_resolveOpened(selected));
    }
    final history = _history!;
    await Future.wait([history.refresh(), ?configuration]);
    if (!mounted ||
        !identical(_history, history) ||
        !_resumeOnOpen ||
        history.error != null) {
      return;
    }
    _resumeOnOpen = false;
    final latest = history.conversations.firstOrNull;
    if (latest == null) {
      _startConversation();
    } else {
      _enterConversation(latest);
    }
  }

  /// Push/initial navigation knows only an ID; load it for context and status.
  Future<void> _resolveOpened(String id) async {
    final epoch = _epoch;
    try {
      final conversation = await widget.client.getConversation(id);
      if (mounted && epoch == _epoch && _selected == id) {
        setState(() => _opened = conversation);
      }
    } catch (_) {
      // Optional detail: the thread still works without it.
    }
  }

  Widget _pagination({required bool messages}) {
    final history = _history;
    if (history == null || history.isLoading) return const SizedBox(height: 48);
    if (history.error != null || history.hasMore) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(
            _resumeOnOpen
                ? _load()
                : history.error == null
                ? history.loadNext()
                : history.retry(),
          ),
          child: Text(
            history.error != null
                ? _text(ChatText.retryHistory)
                : messages
                ? _text(ChatText.olderMessages)
                : _text(ChatText.moreConversations),
          ),
        ),
      );
    }
    if (!messages) return const SizedBox.shrink();
    if (_messages.isNotEmpty) return const SizedBox.shrink();
    return _EmptyThread(
      _text(ChatText.emptyThreadTitle),
      _text(ChatText.emptyThreadBody),
    );
  }

  Widget _draftGreeting() {
    final configured = _config?.greeting ?? '';
    final greeting = configured.isEmpty
        ? _text(ChatText.greetingFallback)
        : configured;
    return _GreetingBubble(
      text: greeting,
      meta: "$_appName · ${_text(ChatText.justNow)}",
      semanticsLabel: '$_appName: $greeting',
    );
  }

  String _code(Object error) =>
      error is ProtodeskChatException ? error.code : 'chat.request_failed';
  Future<String?> _ensureConversation() async {
    if (_selected != null) return _selected;
    if (_creating || !_newThread) return null;
    final epoch = _epoch;
    _createId ??= ProtodeskChatClient.newOperationId();
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final conversation = await widget.client.createConversation(
        idempotencyKey: _createId!,
        preChat: _newPreChat!,
        routingChoiceId: _newRouting,
      );
      if (!mounted || epoch != _epoch) return null;
      setState(() {
        _newPreChat = null;
        _selected = conversation.id;
        _opened = conversation;
        _messages = [];
        _createId = null;
        _settingUp = false;
        _setupStatus = null;
      });
      unawaited(_load());
      return conversation.id;
    } catch (error) {
      if (!mounted || epoch != _epoch) return null;
      final code = _code(error);
      const stale = {
        'chat.configuration_stale',
        'chat.pre_chat_invalid',
        'chat.routing_choice_invalid',
      };
      if (stale.contains(code)) {
        // The server's form changed: reload it and ask again, as the web does.
        _createId = null;
        try {
          final config = await widget.client.getConfiguration(refresh: true);
          if (!mounted || epoch != _epoch) return null;
          setState(() {
            _config = config;
            _settingUp = true;
            _newPreChat = null;
            _setupStatus = _text(ChatText.setupChanged);
          });
        } catch (refresh) {
          if (mounted && epoch == _epoch) {
            setState(() => _error = _code(refresh));
          }
        }
      } else {
        setState(() => _error = code);
      }
      return null;
    } finally {
      if (mounted && epoch == _epoch) setState(() => _creating = false);
    }
  }

  Future<void> _confirmStartOver() async {
    final client = widget.client;
    var busy = false;
    String? failure;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      animationStyle: MediaQuery.disableAnimationsOf(context)
          ? AnimationStyle.noAnimation
          : null,
      builder: (dialogContext) => Theme(
        data: _theme,
        child: StatefulBuilder(
          builder: (dialogContext, setDialog) => AlertDialog(
            title: Text(_text(ChatText.startOverTitle)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_text(ChatText.startOverBody)),
                if (failure != null) ...[
                  const SizedBox(height: 12),
                  _ChatStatus(
                    failure!,
                    style: TextStyle(color: _theme.colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: Text(_text(ChatText.cancel)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _theme.colorScheme.error,
                  foregroundColor: _theme.colorScheme.onError,
                ),
                onPressed: busy
                    ? null
                    : () async {
                        setDialog(() {
                          busy = true;
                          failure = null;
                        });
                        try {
                          await client.resetAnonymousIdentity();
                        } catch (_) {
                          // Credentials are kept when the server reset fails.
                          setDialog(() {
                            busy = false;
                            failure = _text(ChatText.startOverFailed);
                          });
                          return;
                        }
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext).pop();
                        }
                        try {
                          await client.continueAnonymously();
                        } catch (error) {
                          if (mounted) setState(() => _error = _code(error));
                        }
                      },
                child: Text(
                  _text(busy ? ChatText.startingOver : ChatText.startOver),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get _canStartOver =>
      widget.client.identityKind == ChatIdentityKind.anonymous &&
      _config?.capabilities.anonymousIdentityReset == true;

  Future<void> _send() async {
    if (_selected != null) widget.client.setTyping(_selected!, false);
    if (_closed ||
        _saving ||
        _picking ||
        (!_newThread && _selected == null) ||
        (_draft.text.trim().isEmpty && _uploads.isEmpty) ||
        _uploads.any((u) => u.state != ChatUploadState.ready)) {
      return;
    }
    final epoch = _epoch;
    setState(() => _saving = true);
    try {
      final conversation = await _ensureConversation();
      if (!mounted || epoch != _epoch || conversation == null) return;
      if (_uploads.isEmpty) {
        await widget.client.sendQueue.enqueueDurably(
          conversationId: conversation,
          text: _draft.text,
        );
      } else {
        _attachmentSendId ??= ProtodeskChatClient.newOperationId();
        final message = await widget.client.attachments.send(
          conversation,
          _draft.text,
          List.of(_uploads),
        );
        if (!mounted || epoch != _epoch) return;
        _history?.includeMessage(message);
        _uploads.clear();
        _attachmentSendId = null;
      }
      if (!mounted || epoch != _epoch) return;
      _draft.clear();
      setState(() => _error = null);
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = _code(error));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _saving = false);
    }
  }

  Future<void> _pick() async {
    final epoch = _epoch;
    setState(() => _picking = true);
    try {
      final source = await widget.attachmentPicker!();
      if (!mounted || epoch != _epoch || source == null) return;
      final conversation = await _ensureConversation();
      if (!mounted || epoch != _epoch || conversation == null) return;
      // Native pickers may temporarily suspend the app. Wait for foreground
      // reconciliation before attempting an online-only transfer.
      if (!widget.client.attachments.isPersistent &&
          widget.client.connectionState != ChatConnectionState.connected) {
        await widget.client.connectionStates
            .firstWhere((s) => s == ChatConnectionState.connected)
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () => throw const ProtodeskChatException(
                'sdk.attachment_offline_disabled',
              ),
            );
      }
      if (!mounted || epoch != _epoch || conversation != _selected) return;
      final upload = await widget.client.attachments.uploadDurably(
        conversation,
        source,
      );
      if (!mounted || epoch != _epoch || conversation != _selected) return;
      setState(() {
        if (!_uploads.contains(upload)) _uploads.add(upload);
      });
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = _code(error));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _picking = false);
    }
  }

  Widget _uploadTile(ChatAttachmentUpload upload) {
    final source = upload.source;
    final scheme = _theme.colorScheme;
    final failed = upload.state == ChatUploadState.failed;
    final status = upload.error != null
        ? _strings.error(upload.error!.code)
        : upload.state == ChatUploadState.ready
        ? _fileSize(upload.sizeBytes)
        : _strings.status(upload.state.name);
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: failed ? scheme.errorContainer : scheme.surfaceContainerLow,
        border: Border.all(
          color: failed ? scheme.error : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: scheme.surface,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: source != null && source.contentType.startsWith('image/')
                    ? _AttachmentImage(
                        bytes: source.bytes,
                        width: 28,
                        height: 28,
                        cacheWidth: 84,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.broken_image_outlined, size: 16),
                      )
                    : const ExcludeSemantics(child: Text('↥')),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      upload.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    _ChatStatus(
                      status,
                      style: _theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: failed ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!_saving && _attachmentSendId == null) ...[
                if (failed && upload.error?.retryable == true)
                  TextButton(
                    onPressed: () => _queueAction(
                      () => widget.client.attachments.retry(upload),
                    ),
                    child: Text(_text(ChatText.retryUpload)),
                  ),
                IconButton(
                  tooltip: _text(ChatText.removeAttachment),
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(
                      _theme.materialTapTargetSize ==
                              MaterialTapTargetSize.padded
                          ? 48
                          : 24,
                    ),
                  ),
                  icon: const ChatWidgetIcon(ChatGlyph.close, size: 16),
                  onPressed: () {
                    setState(() => _uploads.remove(upload));
                    unawaited(
                      _queueAction(
                        () => widget.client.attachments.cancel(upload),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
          if (upload.state == ChatUploadState.uploading)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 36),
              child: LinearProgressIndicator(
                minHeight: 2,
                value: upload.sentBytes / upload.sizeBytes,
                semanticsLabel: _text(ChatText.uploadProgress),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _preview(ChatAttachment attachment) async {
    if (_previewing) return;
    _previewing = true;
    final epoch = _epoch;
    try {
      final bytes = await widget.client.attachments.download(attachment);
      if (!mounted || epoch != _epoch) return;
      if (attachment.contentType.startsWith('image/')) {
        // A scoped dialog is closed on identity change, so decoded pixels do not
        // remain visible after the owning session ends.
        final navigator = Navigator.of(context);
        final route = DialogRoute<void>(
          context: context,
          traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
          animationStyle: MediaQuery.disableAnimationsOf(context)
              ? AnimationStyle.noAnimation
              : null,
          builder: (_) => Theme(
            data: _theme,
            child: AlertDialog(
              scrollable: true,
              title: Text(attachment.filename),
              content: _AttachmentImage(
                bytes: bytes,
                semanticLabel: attachment.filename,
                cacheWidth: 1024,
                errorBuilder: (_, _, _) =>
                    Text(_text(ChatText.previewUnavailable)),
              ),
              actions: [
                TextButton(
                  onPressed: () => navigator.pop(),
                  child: Text(_text(ChatText.close)),
                ),
              ],
            ),
          ),
        );
        _closePreview = () {
          if (route.isActive) navigator.removeRoute(route);
        };
        final subscription = widget.client.states.listen((state) {
          if (state != ChatClientState.ready && route.isActive) {
            navigator.removeRoute(route);
          }
        });
        try {
          await navigator.push(route);
        } finally {
          _closePreview = null;
          await subscription.cancel();
        }
      } else {
        await widget.onOpenAttachment?.call(attachment, bytes);
      }
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = _code(error));
    } finally {
      if (epoch == _epoch) _previewing = false;
    }
  }

  Future<void> _queueAction(Future<void> Function() action) async {
    final epoch = _epoch;
    try {
      await action();
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = _code(error));
    }
  }

  Future<void> _markRead(ChatMessage message) async {
    if (_reportingRead ||
        ModalRoute.of(context)?.isCurrent == false ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    final epoch = _epoch;
    final generation = _readGeneration;
    setState(() => _reportingRead = true);
    try {
      await widget.client.markRead(
        conversationId: message.conversationId,
        throughMessageId: message.id,
      );
      if (mounted && epoch == _epoch && generation == _readGeneration) {
        if (_automaticReadBoundary == null ||
            _newerReadBoundary(message, _automaticReadBoundary!)) {
          _automaticReadBoundary = message;
        }
      }
    } catch (error) {
      if (mounted && epoch == _epoch && generation == _readGeneration) {
        setState(() => _error = _code(error));
      }
    } finally {
      if (mounted && epoch == _epoch && generation == _readGeneration) {
        setState(() => _reportingRead = false);
      }
    }
  }

  String _time(DateTime value) =>
      MaterialLocalizations.of(context)
          .formatTimeOfDay(TimeOfDay.fromDateTime(value.toLocal()));

  Widget _messageTile(ChatMessage message) {
    final pending = widget.client.sendQueue.messages
        .where(
          (p) =>
              p.clientMessageId == message.clientMessageId &&
              p.conversationId == message.conversationId,
        )
        .firstOrNull;
    final kind = switch (message.sender) {
      'endUser' => _BubbleKind.customer,
      'system' => _BubbleKind.system,
      _ => _BubbleKind.agent,
    };
    final scheme = _theme.colorScheme;
    final foreground = switch (kind) {
      _BubbleKind.customer => scheme.onPrimary,
      _BubbleKind.system => scheme.onSurfaceVariant,
      _BubbleKind.agent => scheme.onSurface,
    };
    final status = pending == null
        ? null
        : pending.error == null
        ? _strings.status(pending.state.name)
        : _strings.error(pending.error!.code);
    // Unsent messages carry their queue status instead of a time.
    final meta = pending == null ? _time(message.createdAt) : '';
    final actions = <Widget>[
      if (pending != null && pending.state != ChatSendState.sending) ...[
        if (pending.error?.retryable == true)
          TextButton(
            onPressed: () => _queueAction(
              () => widget.client.sendQueue.retry(pending.clientMessageId),
            ),
            child: Text(_text(ChatText.retry)),
          ),
        IconButton(
          tooltip: _text(ChatText.discardMessage),
          icon: const Icon(Icons.close_rounded),
          onPressed: () => _queueAction(
            () => widget.client.sendQueue.discard(pending.clientMessageId),
          ),
        ),
      ],
    ];
    return KeyedSubtree(
      key: ValueKey(message.id),
      child: _MessageBubble(
        kind: kind,
        meta: meta,
        label: kind == _BubbleKind.system
            ? _text(ChatText.automatedNotice)
            : null,
        footer: status == null && actions.isEmpty
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (status != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _ChatStatus(
                        status,
                        style: _theme.textTheme.bodySmall?.copyWith(
                          color: pending?.error == null
                              ? _theme.colorScheme.onSurfaceVariant
                              : _theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ...actions,
                ],
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.text.isNotEmpty)
              Text(
                message.text,
                semanticsLabel:
                    '${_strings.sender(message.sender)}: ${message.text}',
                style: _theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  height: 1.48,
                ),
              ),
            for (final attachment in message.attachments)
              _attachmentChip(
                attachment,
                customer: kind == _BubbleKind.customer,
              ),
          ],
        ),
      ),
    );
  }

  Widget _attachmentChip(ChatAttachment attachment, {required bool customer}) {
    final scheme = _theme.colorScheme;
    final foreground = customer ? scheme.onPrimary : scheme.onSurface;
    final enabled =
        attachment.contentType.startsWith('image/') ||
        widget.onOpenAttachment != null;
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: SizedBox(
        width: double.infinity,
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: foreground,
            disabledForegroundColor: foreground.withValues(alpha: .68),
            backgroundColor: customer
                ? foreground.withValues(alpha: .12)
                : scheme.surfaceContainerLow,
            side: BorderSide(
              color: customer
                  ? foreground.withValues(alpha: .16)
                  : scheme.outlineVariant,
            ),
            minimumSize: Size(
              0,
              _theme.materialTapTargetSize == MaterialTapTargetSize.padded
                  ? 48
                  : 29,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            alignment: AlignmentDirectional.centerStart,
            textStyle: _theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.2,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: enabled ? () => _preview(attachment) : null,
          child: Text(
            '↓ ${attachment.filename} · ${_fileSize(attachment.sizeBytes)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: _strings.format(ChatText.attachment, {
              'name': attachment.filename,
              'size': _strings.number(attachment.sizeBytes),
            }),
          ),
        ),
      ),
    );
  }

  String _fileSize(int bytes) {
    if (bytes < 1024) return '${_strings.number(bytes)} B';
    if (bytes < 1024 * 1024) {
      return '${_strings.number((bytes / 1024).ceil())} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get _closed => _openConversation?.status == 'closed';

  /// The newest non-system message is the customer's and was accepted: show
  /// that a reply is expected (web widget `awaitingReply`).
  bool get _awaitingReply {
    final status = _openConversation?.status ?? 'open';
    if (status != 'open' && status != 'pending') return false;
    for (final message in _messages) {
      if (message.sender == 'system') continue;
      return message.sender == 'endUser' &&
          message.id.startsWith('msg_') &&
          !widget.client.sendQueue.messages.any(
            (p) => p.clientMessageId == message.clientMessageId,
          );
    }
    return false;
  }

  Widget _composer() {
    final scheme = _theme.colorScheme;
    if (_closed) return _ThreadNote(_text(ChatText.closedNotice));
    final busy = _saving || _creating || _attachmentSendId != null;
    final attach =
        widget.attachmentPicker == null ||
            _config?.capabilities.attachments == false
        ? null
        : IconButton(
            style: IconButton.styleFrom(minimumSize: const Size.square(32)),
            tooltip: _text(ChatText.attachFile),
            icon: const ChatWidgetIcon(ChatGlyph.attachment, size: 19),
            onPressed: busy || _picking ? null : _pick,
          );
    final send = ValueListenableBuilder<TextEditingValue>(
      valueListenable: _draft,
      builder: (context, value, _) {
        final canSend =
            !_saving &&
            !_picking &&
            _uploads.every((u) => u.state == ChatUploadState.ready) &&
            (value.text.trim().isNotEmpty || _uploads.isNotEmpty);
        return IconButton(
          tooltip: _text(ChatText.send),
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(minimumSize: const Size.square(34)),
          icon: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: canSend ? scheme.primary : scheme.outlineVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                : Text(
                    '↑',
                    textScaler: TextScaler.noScaling,
                    style: _theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 18,
                      height: 1,
                      color: canSend
                          ? scheme.onPrimary
                          : ChatTheme.faint(_theme),
                    ),
                  ),
          ),
          onPressed: canSend ? _send : null,
        );
      },
    );
    final field = TextField(
      controller: _draft,
      style: _theme.textTheme.bodyMedium,
      inputFormatters: [LengthLimitingTextInputFormatter(20000)],
      focusNode: _composerFocus,
      autofocus:
          _newThread &&
          (RendererBinding.instance.mouseTracker.mouseIsConnected ||
              const {
                TargetPlatform.macOS,
                TargetPlatform.windows,
                TargetPlatform.linux,
              }.contains(_theme.platform)),
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => unawaited(_send()),
      onChanged: (text) {
        if (_selected != null && ModalRoute.of(context)?.isCurrent != false) {
          widget.client.setTyping(_selected!, text.trim().isNotEmpty);
        }
      },
      readOnly: busy,
      minLines: 1,
      maxLines: 5,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        hintText: _text(ChatText.messageHint),
        hintStyle: _theme.textTheme.bodyMedium?.copyWith(
          color: ChatTheme.faint(_theme),
        ),
        semanticCounterText: '',
        filled: false,
        isDense: true,
        constraints: BoxConstraints(
          minHeight:
              _theme.materialTapTargetSize == MaterialTapTargetSize.padded
              ? 48
              : 32,
        ),
        contentPadding: const EdgeInsets.fromLTRB(0, 7, 0, 5),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: _composerFocus,
          builder: (context, _) => DecoratedBox(
            key: const ValueKey('composer-surface'),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              border: Border.all(
                color: _composerFocus.hasFocus
                    ? Color.lerp(
                        ChatBrandColors.resolve(_theme).borderStrong,
                        scheme.primary,
                        .44,
                      )!
                    : ChatBrandColors.resolve(_theme).borderStrong,
                width: 1,
              ),
              boxShadow: _composerFocus.hasFocus
                  ? [
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: .07),
                        spreadRadius: 3,
                      ),
                    ]
                  : null,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(11, 8, 8, 8),
              child: Row(
                spacing: 8,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (attach != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 1),
                      child: attach,
                    ),
                  Expanded(
                    child: Focus(
                      canRequestFocus: false,
                      onKeyEvent: (_, event) {
                        if (event.logicalKey != LogicalKeyboardKey.enter ||
                            HardwareKeyboard.instance.isShiftPressed ||
                            !_draft.value.composing.isCollapsed) {
                          return KeyEventResult.ignored;
                        }
                        if (event is KeyDownEvent) unawaited(_send());
                        return KeyEventResult.handled;
                      },
                      child: field,
                    ),
                  ),
                  send,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  ChatConversation? get _openConversation {
    for (final conversation in _conversations) {
      if (conversation.id == _selected) return conversation;
    }
    return _opened?.id == _selected ? _opened : null;
  }

  /// Mirrors the server rule so the prompt is only requested when it can apply:
  /// anonymous, not closed, and at least one saved customer message.
  bool get _contactEligible =>
      _selected != null &&
      widget.client.identityKind == ChatIdentityKind.anonymous &&
      _openConversation?.status != 'closed' &&
      _messages.any(
        (message) =>
            message.sender == 'endUser' && message.id.startsWith('msg_'),
      );

  /// In a compact (scrolling) column the message pane keeps most of the
  /// screen, never less than 240 px.
  Widget _historyPane({
    required bool compact,
    required double available,
    required Widget child,
  }) => compact
      ? SizedBox(height: max(240, available * 0.6), child: child)
      : Expanded(child: child);

  @override
  void dispose() {
    _closePresentation?.call();
    _readTimer?.cancel();
    ++_epoch;
    _clearAttachments();
    WidgetsBinding.instance.removeObserver(this);
    _releaseHistory();
    unawaited(_attachmentSubscription?.cancel());
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_visible) unawaited(widget.client.disconnect());
    unawaited(_unread?.dispose());
    unawaited(_help?.dispose());
    _composerFocus.dispose();
    _draft.dispose();
    _homeSearch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme,
    child: Builder(builder: _buildScreen),
  );

  Widget _buildScreen(BuildContext context) {
    final ready = widget.client.state == ChatClientState.ready;
    final thread = ready && (_selected != null || _newThread);
    final setup = ready && !thread && _settingUp && _config != null;
    final close = widget.onClose == null
        ? null
        : IconButton(
            tooltip: _text(ChatText.close),
            onPressed: widget.onClose,
            icon: const ChatWidgetIcon(ChatGlyph.close, size: 22),
          );
    final brand = _BrandMark(logoUrl: _config?.appearance.logoUrl);
    final header = thread
        ? _MessengerHeader(
            title: _appName,
            brand: brand,
            status: _ConnectionStatus(
              widget.client.connectionState,
              _strings.status(widget.client.connectionState.name),
            ),
            leading: IconButton(
              tooltip: _text(ChatText.conversations),
              onPressed:
                  _saving || _creating || _picking || _attachmentSendId != null
                  ? null
                  : _showConversations,
              icon: const ChatWidgetIcon(ChatGlyph.back, size: 22),
            ),
            actions: [
              if (_canStartOver && _selected != null)
                PopupMenuButton<void>(
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(
                      _theme.materialTapTargetSize ==
                              MaterialTapTargetSize.padded
                          ? 48
                          : 36,
                    ),
                    foregroundColor: _theme.colorScheme.onSurfaceVariant,
                  ),
                  icon: const ChatWidgetIcon(ChatGlyph.more, size: 22),
                  tooltip: _text(ChatText.chatOptions),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      onTap: () => unawaited(_confirmStartOver()),
                      child: Text(_text(ChatText.startOver)),
                    ),
                  ],
                ),
              ?close,
            ],
          )
        : setup
        ? _MessengerHeader(
            title: _appName,
            brand: brand,
            status: _ConnectionStatus(
              widget.client.connectionState,
              _strings.status(widget.client.connectionState.name),
            ),
            leading: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _creating ? null : _showConversations,
              icon: const ChatWidgetIcon(ChatGlyph.back, size: 22),
            ),
            actions: [?close],
          )
        : ready && _visibleSection != ChatMessengerSection.messages
        ? null
        : _MessengerHeader(
            title: ready ? _text(ChatText.messages) : _appName,
            status: ready
                ? null
                : _ChatStatus(
                    _text(ChatText.signedOut),
                    style: _theme.textTheme.bodySmall,
                  ),
            actions: [?close],
          );
    final navigation =
        ready && !thread && !setup && (!_resumeOnOpen || _error != null);
    return LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth > 480;
        final body = ready && _resumeOnOpen && _error == null
            ? _OpeningChat(label: _text(ChatText.loading), close: close)
            : _messengerBody(
                wide: wide,
                ready: ready,
                thread: thread,
                setup: setup,
                header: header,
                close: close,
              );
        final panel = Scaffold(
          backgroundColor: _theme.scaffoldBackgroundColor,
          bottomNavigationBar: navigation
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: _theme.colorScheme.outlineVariant),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
                    child: _navigation(),
                  ),
                )
              : null,
          body: body,
        );
        if (!wide) return panel;
        final onLeft = _config?.launcherOnLeft == true;
        final showToggle = widget.onClose != null && bounds.maxHeight >= 520;
        return SafeArea(
          child: Align(
            alignment: onLeft ? Alignment.bottomLeft : Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: onLeft
                    ? CrossAxisAlignment.start
                    : CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            _articleExpanded &&
                                _visibleSection == ChatMessengerSection.help
                            ? 760
                            : 380,
                        maxHeight: 620,
                      ),
                      child: Material(
                        elevation: 12,
                        color: _theme.scaffoldBackgroundColor,
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: BorderSide(
                            color: _theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: panel,
                      ),
                    ),
                  ),
                  if (showToggle) ...[
                    const SizedBox(height: 16),
                    ChatLauncherButton(
                      onPressed: widget.onClose,
                      expanded: true,
                      label: _text(ChatText.closeChat),
                      color: _theme.colorScheme.primary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _messengerBody({
    required bool wide,
    required bool ready,
    required bool thread,
    required bool setup,
    required Widget? header,
    required Widget? close,
  }) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Large text in a conversation: header, footer and composer no
          // longer leave room for the message pane, so the whole column
          // scrolls instead. Other sections already scroll on their own.
          final compact =
              thread &&
              (constraints.maxHeight < 360 ||
                  (MediaQuery.textScalerOf(context).scale(16) > 24 &&
                      constraints.maxHeight < 900));
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?header,
              if (_loading)
                MediaQuery.disableAnimationsOf(context)
                    ? _ThreadNote(_text(ChatText.loading), live: true)
                    : LinearProgressIndicator(
                        minHeight: 2,
                        semanticsLabel: _text(ChatText.loading),
                      ),
              if (_error != null) _errorBanner(),
              if (widget.client.attachments.storageBlocked)
                TextButton(
                  onPressed: () =>
                      _queueAction(widget.client.attachments.retryPersistence),
                  child: Text(_text(ChatText.retryAttachmentStorage)),
                ),
              if (widget.client.sendQueue.storageBlocked)
                TextButton(
                  onPressed: () async {
                    try {
                      await widget.client.sendQueue.retryPersistence();
                    } catch (error) {
                      if (mounted) setState(() => _error = _code(error));
                    }
                  },
                  child: Text(_text(ChatText.retryStorage)),
                ),
              _historyPane(
                compact: compact,
                available: constraints.maxHeight,
                child: !ready
                    ? Center(child: Text(_text(ChatText.signIn)))
                    : thread
                    ? _newThread
                          ? SingleChildScrollView(child: _draftGreeting())
                          : _threadList()
                    : setup
                    ? Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 380),
                          child: _ConversationSetup(
                            key: ValueKey('setup-${_setupStatus != null}'),
                            config: _config!,
                            strings: _strings,
                            submitting: _creating,
                            status: _setupStatus,
                            onSubmit: _compose,
                          ),
                        ),
                      )
                    : switch (_visibleSection) {
                        ChatMessengerSection.home => _homeView(close),
                        ChatMessengerSection.messages => Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 376),
                            child: _conversationList(),
                          ),
                        ),
                        ChatMessengerSection.help => _HelpSection(
                          key: _helpPageKey,
                          controller: _help!,
                          strings: _helpStrings,
                          initialRoute: _helpEntry,
                          onOpenLink: widget.onOpenLink,
                          contacting: _creating,
                          onContactSupport: _startConversation,
                          close: close,
                          expanded: _articleExpanded,
                          onExpand: (v) => setState(() => _articleExpanded = v),
                        ),
                      },
              ),
              if (thread) ..._threadFooter(),
            ],
          );
          final body = compact
              ? NotificationListener<ScrollNotification>(
                  onNotification: (event) {
                    if (event.depth == 0) {
                      _visibleSince.clear();
                      if (event is ScrollStartNotification) {
                        _scrollingMessages = true;
                      }
                      if (event is ScrollEndNotification) {
                        _scrollingMessages = false;
                      }
                    }
                    return false;
                  },
                  child: SingleChildScrollView(child: content),
                )
              : content;
          // Wide screens get a centred column, like the web widget's panel.
          return FocusTraversalGroup(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: body,
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _navigation() {
    final unread = _unread?.isStale == false ? _unread?.count ?? 0 : 0;
    const messageIcon = ChatWidgetIcon(ChatGlyph.message, size: 21);
    final messagesIcon = unread > 0
        ? Badge(
            backgroundColor: const Color(0xffdc2626),
            textColor: Colors.white,
            label: Text(unread > 99 ? "99+" : _strings.number(unread)),
            child: messageIcon,
          )
        : messageIcon;
    final sections = [
      ChatMessengerSection.home,
      ChatMessengerSection.messages,
      if (_helpAvailable || _visibleSection == ChatMessengerSection.help)
        ChatMessengerSection.help,
    ];
    void select(int index) {
      final section = sections[index];
      if (section == _visibleSection && section != ChatMessengerSection.help) {
        return;
      }
      _resumeOnOpen = false;
      _articleExpanded = false;
      if (section == ChatMessengerSection.help) {
        _openHelp(const _HelpRoot());
      } else {
        setState(() => _section = section);
      }
    }

    return NavigationBar(
      height: 54,
      labelPadding: EdgeInsets.zero,
      selectedIndex: sections.indexOf(_visibleSection),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: select,
      destinations: [
        NavigationDestination(
          icon: const ChatWidgetIcon(ChatGlyph.home, size: 21),

          label: _text(ChatText.home),
        ),
        NavigationDestination(
          icon: messagesIcon,

          label: _text(ChatText.messages),
          tooltip: unread > 0
              ? '${_text(ChatText.messages)}, ${_strings.unread(unread)}'
              : null,
        ),
        if (sections.contains(ChatMessengerSection.help))
          NavigationDestination(
            icon: const ChatWidgetIcon(ChatGlyph.help, size: 21),

            label: _text(ChatText.help),
          ),
      ],
    );
  }

  String _date(DateTime? value) {
    if (value == null) return '';
    final local = value.toLocal(), now = DateTime.now();
    return local.year == now.year &&
            local.month == now.month &&
            local.day == now.day
        ? _time(value)
        : MaterialLocalizations.of(context).formatShortMonthDay(local);
  }

  void _enterConversation(ChatConversation conversation) {
    _resumeOnOpen = false;
    setState(() {
      _selected = conversation.id;
      _opened = conversation;
      _messages = [];
    });
    unawaited(_load());
  }

  Widget _homeView(Widget? close) {
    final active = _conversations
        .where((c) => c.status == 'open' || c.status == 'pending')
        .firstOrNull;
    final recent = _conversations.where((c) => c.id != active?.id).firstOrNull;
    final links = widget.onOpenLink == null
        ? const <ChatWidgetLink>[]
        : _config?.links ?? const <ChatWidgetLink>[];
    String subject(ChatConversation c) =>
        c.subject.isEmpty ? _text(ChatText.conversation) : c.subject;
    String? unread(ChatConversation c) =>
        !c.unreadCountIsStale && c.unreadCount > 0
        ? _strings.number(c.unreadCount)
        : null;

    final contact = active == null
        ? _HomeContactCard(
            key: const ValueKey('home-start'),
            title: _creating
                ? _text(ChatText.starting)
                : _text(ChatText.sendUsMessage),
            subtitle: _text(ChatText.replyHere),
            onTap: _creating ? null : _startConversation,
          )
        : _HomeContactCard(
            key: ValueKey(active.id),
            title: _text(ChatText.continueConversation),
            subtitle: [
              subject(active),
              if (_date(active.updatedAt).isNotEmpty) _date(active.updatedAt),
            ].join(' · '),
            unread: unread(active),
            semanticsLabel: [
              _text(ChatText.continueConversation),
              subject(active),
              if (unread(active) != null) _strings.unread(active.unreadCount),
            ].join(', '),
            onTap: () => _enterConversation(active),
          );

    return SingleChildScrollView(
      key: const ValueKey('messenger-home'),
      child: CustomPaint(
        painter: _HomeBackdrop(
          _theme.colorScheme.primary,
          _theme.scaffoldBackgroundColor,
        ),
        child: Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 380),
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _HomeIntro(
                  brand: _BrandMark(logoUrl: _config?.appearance.logoUrl),
                  name: _appName,
                  status: _ConnectionStatus(
                    widget.client.connectionState,
                    _strings.status(widget.client.connectionState.name),
                  ),
                  title: _config?.headerTitle ?? _text(ChatText.homeTitle),
                  eyebrow: _text(ChatText.homeEyebrow),
                  body: _text(
                    _helpAvailable
                        ? ChatText.homeWelcomeHelp
                        : ChatText.homeWelcome,
                  ),
                  close: close,
                ),
                // The rest of Home rises 22 px so the contact card overlaps the
                // intro's lower edge by a fixed amount at any text size, as on the web.
                Transform.translate(
                  offset: const Offset(0, -22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 324),
                            child: contact,
                          ),
                        ),
                      ),
                      if (recent != null) ...[
                        _HomeSectionTitle(_text(ChatText.recentConversation)),
                        _ConversationCard(
                          key: ValueKey(recent.id),
                          recent: true,
                          title: subject(recent),
                          subtitle: [
                            _strings.status(recent.status),
                            if (_date(recent.updatedAt).isNotEmpty)
                              _date(recent.updatedAt),
                          ].join(' · '),
                          unread: unread(recent),
                          brand: _BrandMark(
                            logoUrl: _config?.appearance.logoUrl,
                            size: 40,
                          ),
                          onTap: () => _enterConversation(recent),
                        ),
                      ],
                      if (_helpAvailable) ...[
                        _HomeSectionTitle(_text(ChatText.findAnswer)),
                        _homeHelp(),
                      ],
                      if (links.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _HomeLinks(
                          links: links,
                          hint: _text(ChatText.opensInBrowser),
                          onOpen: (url) => unawaited(
                            widget.onOpenLink!(url).catchError((Object _) {}),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Home's "Find an answer": search into Help, three featured articles (or
  /// topics when none are featured) and "View all articles".
  Widget _homeHelp() {
    final help = _help!;
    final strings = _helpStrings;
    final manifest = help.manifest;
    final scheme = _theme.colorScheme;
    final rows = <Widget>[];
    if (manifest != null) {
      final featured = manifest.featuredArticles.take(3).toList();
      if (featured.isNotEmpty) {
        for (final article in featured) {
          rows.add(
            _HelpArticleRow(
              key: ValueKey('home-help-${article.id}'),
              inlineArrow: true,
              title: article.title,
              excerpt: '',
              onTap: () => _openHelp(
                _HelpArticleRoute(
                  article.id,
                  article.slug,
                  help.article(article.id),
                ),
              ),
            ),
          );
        }
      } else {
        for (final collection in manifest.rootCollections.take(3)) {
          rows.add(
            _HelpCollectionRow(
              collection: collection,
              count: strings.articles(collection.articleCount),
              onTap: () => _openHelp(_HelpListingRoute(collection)),
            ),
          );
        }
      }
      rows.add(
        _HelpArticleRow(
          title: strings.text(ChatText.viewAllArticles),
          browse: true,
          excerpt: '',
          inlineArrow: true,
          onTap: () => _openHelp(const _HelpListingRoute(null)),
        ),
      );
    }
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _HelpSearchField(
                controller: _homeSearch,
                home: true,
                hint: strings.text(ChatText.searchHelp),
                clearLabel: strings.text(ChatText.clearSearch),
                onChanged: (_) {},
                onSubmitted: (value) => _openHelp(_HelpRoot(value.trim())),
              ),
            ),
            if (manifest == null)
              help.error == null
                  ? const _HelpSkeleton(rows: 2)
                  : TextButton(
                      onPressed: () => unawaited(help.load(refresh: true)),
                      child: Text(
                        '${strings.text(ChatText.helpUnavailable)} · '
                        '${strings.text(ChatText.tryAgain)}',
                      ),
                    )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final row in rows)
                      if (row == rows.last)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: row,
                          ),
                        )
                      else ...[
                        row,
                        Divider(height: 1, color: scheme.outlineVariant),
                      ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showConversations() {
    ++_epoch;
    _reportingRead = false;
    if (_selected != null) widget.client.setTyping(_selected!, false);
    _clearAttachments();
    _draft.clear();
    setState(() {
      _newPreChat = null;
      _createId = null;
      _settingUp = false;
      _section = ChatMessengerSection.messages;
      _selected = null;
      _opened = null;
      _messages = [];
    });
    unawaited(_load());
  }

  Widget _errorBanner() => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    constraints: const BoxConstraints(maxHeight: 120),
    decoration: BoxDecoration(
      color: _theme.colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: SingleChildScrollView(
      child: _ChatStatus(
        _strings.error(_error!),
        style: _theme.textTheme.bodyMedium?.copyWith(
          color: _theme.colorScheme.onErrorContainer,
        ),
      ),
    ),
  );

  Widget _conversationList() {
    final strings = _strings;
    final date = _date;

    return ListView.builder(
      key: const ValueKey('conversation-history'),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      itemCount: _conversations.length + 3,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _conversations.isEmpty
              ? _SectionHeading(
                  _text(ChatText.noMessages),
                  _text(ChatText.noMessagesHint),
                )
              : _SectionHeading(
                  _text(ChatText.yourConversations),
                  _text(ChatText.pickUp),
                );
        }
        if (index == _conversations.length + 1) {
          return _pagination(messages: false);
        }
        if (index == _conversations.length + 2) {
          return Padding(
            padding: EdgeInsets.only(
              top: _conversations.isEmpty ? 0 : 20,
              bottom: 28,
            ),
            child: _StartButton(
              onPressed: _creating ? null : _startConversation,
              label: _text(
                _creating ? ChatText.starting : ChatText.startConversation,
              ),
            ),
          );
        }
        final conversation = _conversations[index - 1];
        final subject = conversation.subject.isEmpty
            ? _text(ChatText.conversation)
            : conversation.subject;
        final when = date(conversation.updatedAt);
        final subtitle = [
          strings.status(conversation.status),
          if (when.isNotEmpty) when,
        ].join(' · ');
        final unread =
            !conversation.unreadCountIsStale && conversation.unreadCount > 0
            ? strings.number(conversation.unreadCount)
            : null;
        return _ConversationCard(
          key: ValueKey(conversation.id),
          title: subject,
          subtitle: subtitle,
          unread: unread,
          semanticsLabel: [
            subject,
            subtitle,
            if (unread != null) strings.unread(conversation.unreadCount),
          ].join(', '),
          brand: _BrandMark(logoUrl: _config?.appearance.logoUrl, size: 40),
          onTap: () => _enterConversation(conversation),
        );
      },
    );
  }

  Widget _threadList() => NotificationListener<ScrollNotification>(
    onNotification: (notification) {
      if (notification.depth == 0) {
        _visibleSince.clear();
        if (notification is ScrollStartNotification) _scrollingMessages = true;
        if (notification is ScrollEndNotification) _scrollingMessages = false;
      }
      return false;
    },
    child: SizedBox(
      key: _readViewport,
      child: Align(
        alignment: Alignment.topCenter,
        child: ListView.builder(
          shrinkWrap: _messages.length < 12,
          key: ValueKey('message-history-$_selected'),
          reverse: true,
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          itemCount: _messages.length + 2,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                children: [
                  if (_contactEligible)
                    _ContactPrompt(
                      key: ValueKey('contact-$_epoch-$_selected'),
                      client: widget.client,
                      conversationId: _selected!,
                      strings: _strings,
                    ),
                  if (_awaitingReply)
                    _ThreadNote(_text(ChatText.awaitingReply), live: true),
                ],
              );
            }
            if (index == _messages.length + 1) {
              return _pagination(messages: true);
            }
            final message = _messages[index - 1];
            return SizedBox(
              key: _readTiles.putIfAbsent(message.id, () => GlobalKey()),
              child: _messageTile(message),
            );
          },
        ),
      ),
    ),
  );

  List<Widget> _threadFooter() => [
    if (_attachmentSendId != null && !_saving)
      TextButton(
        onPressed: () {
          setState(() {
            _clearAttachments(discard: true);
            _draft.clear();
          });
        },
        child: Text(_text(ChatText.discardDraft)),
      ),
    if (_uploads.isNotEmpty)
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 156),
        child: ListView(
          shrinkWrap: true,
          children: _uploads.map(_uploadTile).toList(),
        ),
      ),
    if (_selected != null && widget.client.typingAgents(_selected!).isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            const _TypingDots(),
            const SizedBox(width: 8),
            Expanded(
              child: _ChatStatus(
                widget.client.typingAgents(_selected!).length == 1
                    ? _text(ChatText.typing)
                    : _text(ChatText.typingMany),
                style: _theme.textTheme.bodySmall?.copyWith(
                  color: _theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    Padding(
      padding: EdgeInsets.fromLTRB(
        18,
        _uploads.isEmpty ? 10 : 2,
        18,
        MediaQuery.viewInsetsOf(context).bottom > 0 ? 2 : 5,
      ),
      child: _composer(),
    ),
    if (MediaQuery.viewInsetsOf(context).bottom == 0)
      _PoweredBy(_text(ChatText.poweredBy)),
  ];
}

class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({
    required this.bytes,
    required this.cacheWidth,
    required this.errorBuilder,
    this.width,
    this.height,
    this.semanticLabel,
  });
  final String? semanticLabel;
  final Uint8List bytes;
  final int cacheWidth;
  final double? width, height;
  final ImageErrorWidgetBuilder errorBuilder;
  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  late ImageProvider _provider;
  @override
  void initState() {
    super.initState();
    _update();
  }

  void _update() {
    _provider = ResizeImage(
      MemoryImage(widget.bytes),
      width: widget.cacheWidth,
    );
  }

  @override
  void didUpdateWidget(covariant _AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.cacheWidth != widget.cacheWidth) {
      unawaited(_provider.evict());
      _update();
    }
  }

  @override
  void dispose() {
    unawaited(_provider.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
    image: _provider,
    semanticLabel: widget.semanticLabel,
    excludeFromSemantics: widget.semanticLabel == null,
    width: widget.width,
    height: widget.height,
    errorBuilder: widget.errorBuilder,
  );
}

/// Live regions for Android; debounced, view-scoped announcements on iOS.
class _ChatStatus extends StatefulWidget {
  const _ChatStatus(this.text, {this.style});
  final String text;
  final TextStyle? style;
  @override
  State<_ChatStatus> createState() => _ChatStatusState();
}

class _ChatStatusState extends State<_ChatStatus> {
  Timer? _announcement;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleAnnouncement();
    });
  }

  @override
  void didUpdateWidget(covariant _ChatStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) _scheduleAnnouncement();
  }

  void _scheduleAnnouncement() {
    _announcement?.cancel();
    _announcement = Timer(const Duration(milliseconds: 300), () {
      if (!mounted ||
          Theme.of(context).platform != TargetPlatform.iOS ||
          !MediaQuery.supportsAnnounceOf(context) ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent == false ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed)) {
        return;
      }
      unawaited(
        SemanticsService.sendAnnouncement(
          View.of(context),
          widget.text,
          Directionality.of(context),
        ).catchError((Object _) {}),
      );
    });
  }

  @override
  void dispose() {
    _announcement?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(widget.text, style: widget.style),
  );
}
