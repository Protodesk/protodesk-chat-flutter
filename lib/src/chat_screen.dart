import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'client.dart';
import 'models.dart';
import 'localizations.dart';
import 'theme.dart';
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
    this.initialSection = ChatMessengerSection.home,
    this.onOpenLink,
    this.initialHelpArticleId,
  });
  final ProtodeskChatClient client;

  /// Overrides colours and fonts. Without it the Chat App's brand colour and
  /// colour scheme are used once loaded, otherwise the host Theme.
  final ThemeData? theme;

  /// Shows a close button that calls this (for example, popping the route).
  final VoidCallback? onClose;

  /// Section shown first when no conversation is opened directly.
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
    with WidgetsBindingObserver {
  ChatLocalizations get _strings =>
      widget.localizations ?? ChatLocalizations.of(context);
  String _text(ChatText key) => _strings.text(key);
  ThemeData get _theme =>
      ChatTheme.accessible(widget.theme ?? _brandTheme ?? Theme.of(context));

  ChatAppConfiguration? _config;
  ThemeData? get _brandTheme {
    final color = _config?.appearance.primaryColor;
    if (color == null) return null;
    final dark = switch (_config!.appearance.colorScheme) {
      ChatColorScheme.light => false,
      ChatColorScheme.dark => true,
      ChatColorScheme.system =>
        MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    return dark
        ? ChatTheme.dark(brandColor: Color(color))
        : ChatTheme.light(brandColor: Color(color));
  }

  String get _appName => _config?.name ?? _text(ChatText.support);

  Future<void> _loadConfiguration() async {
    final epoch = _epoch;
    try {
      final config = await widget.client.getConfiguration();
      if (mounted && epoch == _epoch) setState(() => _config = config);
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
  late ChatMessengerSection _section = widget.initialSection;

  /// The pre-chat step is open; [_setupStatus] explains a stale-form reload.
  bool _settingUp = false;
  String? _setupStatus;

  bool get _needsSetup =>
      _config?.requiresConversationSetup == true &&
      widget.preChat.isEmpty &&
      widget.routingChoiceId == null;

  /// Every "start a conversation" action goes through the setup step when the
  /// Chat App requires one and the host did not supply the values.
  void _startConversation() {
    if (_creating) return;
    if (_needsSetup) {
      setState(() {
        _settingUp = true;
        _setupStatus = null;
        _createId = null;
      });
    } else {
      unawaited(_create());
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
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize)
      return;
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
      if (message.sender == 'endUser' || !message.id.startsWith('msg_'))
        continue;
      final tile = _readTiles[message.id]?.currentContext?.findRenderObject();
      if (tile is! RenderBox ||
          !tile.attached ||
          !tile.hasSize ||
          tile.size.isEmpty)
        continue;
      final rect = tile.localToGlobal(Offset.zero) & tile.size;
      if (clip.isEmpty ||
          rect.left < clip.left ||
          rect.right > clip.right ||
          rect.top < clip.top ||
          rect.bottom > clip.bottom)
        continue;
      visible.add(message.id);
      final since = _visibleSince.putIfAbsent(message.id, () => _readElapsed);
      if (_readElapsed - since < const Duration(seconds: 1)) continue;
      if (_automaticReadBoundary != null &&
          !_newerReadBoundary(message, _automaticReadBoundary!))
        continue;
      if (candidate == null || _newerReadBoundary(message, candidate))
        candidate = message;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
  int _helpGeneration = 0;

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
    setState(() {
      _helpEntry = entry;
      _helpGeneration++;
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
    _readTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _sampleReadViewport(),
    );
    _bind();
    final article = widget.initialHelpArticleId;
    if (article != null && article.isNotEmpty && _selected == null) {
      _section = ChatMessengerSection.help;
      _helpEntry = _HelpArticleRoute(article, '', _help!.article(article));
    }
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
          _clearAttachments();
          setState(() {
            _config = null;
            _settingUp = false;
            _setupStatus = null;
            _conversations = [];
            _messages = [];
            _selected = null;
            _createId = null;
            _creating = false;
            _loading = false;
            _error = null;
          });
        } else {
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
      _conversations = [];
      _messages = [];
      _selected = null;
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
    if (_config == null) unawaited(_loadConfiguration());
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
    await _history!.refresh();
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
            history.error == null ? history.loadNext() : history.retry(),
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
    if (!messages) return const SizedBox(height: 8);
    if (_messages.isNotEmpty) return const SizedBox(height: 8);
    final greeting = _config?.greeting ?? '';
    return greeting.isEmpty
        ? _EmptyThread(
            _text(ChatText.emptyThreadTitle),
            _text(ChatText.emptyThreadBody),
          )
        : _GreetingBubble(
            text: greeting,
            meta: _appName,
            semanticsLabel: '$_appName: $greeting',
          );
  }

  String _code(Object error) =>
      error is ProtodeskChatException ? error.code : 'chat.request_failed';
  Future<void> _create({
    Map<String, Object>? preChat,
    String? routingChoiceId,
  }) async {
    if (_creating) return;
    final epoch = _epoch;
    final fromSetup = preChat != null;
    _createId ??= ProtodeskChatClient.newOperationId();
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final conversation = await widget.client.createConversation(
        idempotencyKey: _createId!,
        preChat: preChat ?? widget.preChat,
        routingChoiceId: fromSetup ? routingChoiceId : widget.routingChoiceId,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _selected = conversation.id;
        _opened = conversation;
        _messages = [];
        _createId = null;
        _settingUp = false;
        _setupStatus = null;
      });
      await _load();
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      final code = _code(error);
      const stale = {
        'chat.configuration_stale',
        'chat.pre_chat_invalid',
        'chat.routing_choice_invalid',
      };
      if (fromSetup && stale.contains(code)) {
        // The server's form changed: reload it and ask again, as the web does.
        _createId = null;
        try {
          final config = await widget.client.getConfiguration(refresh: true);
          if (!mounted || epoch != _epoch) return;
          setState(() {
            _config = config;
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
    if (_saving ||
        _picking ||
        _selected == null ||
        (_draft.text.trim().isEmpty && _uploads.isEmpty) ||
        _uploads.any((u) => u.state != ChatUploadState.ready))
      return;
    final epoch = _epoch;
    setState(() => _saving = true);
    try {
      if (_uploads.isEmpty) {
        await widget.client.sendQueue.enqueueDurably(
          conversationId: _selected!,
          text: _draft.text,
        );
      } else {
        _attachmentSendId ??= ProtodeskChatClient.newOperationId();
        final message = await widget.client.attachments.send(
          _selected!,
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
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pick() async {
    final epoch = _epoch;
    final conversation = _selected;
    if (conversation == null) return;
    setState(() => _picking = true);
    try {
      final source = await widget.attachmentPicker!();
      if (!mounted ||
          epoch != _epoch ||
          conversation != _selected ||
          source == null)
        return;
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source != null && source.contentType.startsWith('image/'))
            _AttachmentImage(
              bytes: source.bytes,
              width: 48,
              height: 48,
              cacheWidth: 96,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          Text(upload.filename),
          _ChatStatus(
            upload.error == null
                ? _strings.status(upload.state.name)
                : _strings.error(upload.error!.code),
          ),
          if (upload.state == ChatUploadState.uploading)
            LinearProgressIndicator(
              value: upload.sentBytes / (source?.sizeBytes ?? 1),
              semanticsLabel: _text(ChatText.uploadProgress),
            ),
          if (!_saving && _attachmentSendId == null)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (upload.state == ChatUploadState.failed &&
                    upload.error?.retryable == true)
                  TextButton(
                    onPressed: () => _queueAction(
                      () => widget.client.attachments.retry(upload),
                    ),
                    child: Text(_text(ChatText.retryUpload)),
                  ),
                IconButton(
                  tooltip: _text(ChatText.removeAttachment),
                  icon: const Icon(Icons.close_rounded),
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
          if (state != ChatClientState.ready && route.isActive)
            navigator.removeRoute(route);
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
                AppLifecycleState.resumed))
      return;
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
      if (mounted && epoch == _epoch && generation == _readGeneration)
        setState(() => _error = _code(error));
    } finally {
      if (mounted && epoch == _epoch && generation == _readGeneration)
        setState(() => _reportingRead = false);
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
      _BubbleKind.customer => scheme.onSurface,
      _BubbleKind.system => scheme.onSurfaceVariant,
      _BubbleKind.agent => scheme.onSurface,
    };
    final status = pending == null
        ? null
        : pending.error == null
        ? _strings.status(pending.state.name)
        : _strings.error(pending.error!.code);
    // Unsent messages carry their queue status instead of a time.
    final meta = pending != null
        ? ''
        : [
            if (kind == _BubbleKind.agent) _strings.sender(message.sender),
            _time(message.createdAt),
          ].join(' · ');
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
                  height: 1.45,
                ),
              ),
            for (final attachment in message.attachments)
              _attachmentChip(
                attachment,
                customer: kind == _BubbleKind.customer,
              ),
          ],
        ),
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
      ),
    );
  }

  Widget _attachmentChip(ChatAttachment attachment, {required bool customer}) {
    final scheme = _theme.colorScheme;
    final foreground = scheme.onSurface;
    final enabled =
        attachment.contentType.startsWith('image/') ||
        widget.onOpenAttachment != null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          disabledForegroundColor: foreground.withValues(alpha: 0.7),
          backgroundColor: foreground.withValues(alpha: 0.1),
          alignment: AlignmentDirectional.centerStart,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(
          attachment.contentType.startsWith('image/')
              ? Icons.image_outlined
              : Icons.insert_drive_file_outlined,
          size: 18,
        ),
        label: Text(
          _strings.format(ChatText.attachment, {
            'name': attachment.filename,
            'size': _strings.number(attachment.sizeBytes),
          }),
        ),
        onPressed: enabled ? () => _preview(attachment) : null,
      ),
    );
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
    final closed = _closed;
    final busy = _saving || _attachmentSendId != null;
    final attach = widget.attachmentPicker == null
        ? null
        : IconButton(
            tooltip: _text(ChatText.attachFile),
            icon: const Icon(Icons.attach_file_rounded),
            onPressed: closed || busy || _picking ? null : _pick,
          );
    final send = IconButton(
      tooltip: _text(ChatText.send),
      style: IconButton.styleFrom(
        foregroundColor: ChatBrandColors.resolve(_theme).foreground,
      ),
      icon: const Icon(Icons.arrow_upward_rounded, size: 22),
      onPressed:
          closed ||
              _saving ||
              _picking ||
              _uploads.any((u) => u.state != ChatUploadState.ready)
          ? null
          : _send,
    );
    final field = TextField(
      controller: _draft,
      focusNode: _composerFocus,
      enabled: !closed,
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
        semanticCounterText: '',
        filled: false,
        contentPadding: EdgeInsetsDirectional.fromSTEB(
          attach == null ? 14 : 2,
          14,
          4,
          14,
        ),
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
        if (closed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ChatStatus(
              _text(ChatText.closedNotice),
              style: _theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        // The mobile app's composer: one bordered surface holding the tools,
        // the field and the send arrow.
        DecoratedBox(
          key: const ValueKey('composer-surface'),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            border: Border.all(
              color: ChatBrandColors.resolve(_theme).borderStrong,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              ?attach,
              Expanded(child: field),
              send,
            ],
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
    unawaited(widget.client.disconnect());
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
    final thread = ready && _selected != null;
    final setup = ready && !thread && _settingUp && _config != null;
    final close = widget.onClose == null
        ? null
        : IconButton(
            tooltip: _text(ChatText.close),
            onPressed: widget.onClose,
            icon: const Icon(Icons.close_rounded),
          );
    final brand = _BrandMark(
      name: _appName,
      logoUrl: _config?.appearance.logoUrl,
    );
    final header = thread
        ? _MessengerHeader(
            title: _appName,
            brand: brand,
            status:
                widget.client.connectionState == ChatConnectionState.connected
                ? null
                : _ConnectionStatus(
                    widget.client.connectionState,
                    _strings.status(widget.client.connectionState.name),
                  ),
            leading: IconButton(
              tooltip: _text(ChatText.conversations),
              onPressed: _saving || _attachmentSendId != null
                  ? null
                  : _showConversations,
              icon: const BackButtonIcon(),
            ),
            actions: [
              if (_canStartOver)
                PopupMenuButton<void>(
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
            leading: IconButton(
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: _creating
                  ? null
                  : () => setState(() => _settingUp = false),
              icon: const BackButtonIcon(),
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
    final navigation = ready && !thread && !setup;
    // The messenger's own width, not the screen's: split view and embedded
    // hosts get the layout that fits the space they give it.
    return LayoutBuilder(
      builder: (context, constraints) =>
          _scaffold(constraints.maxWidth >= 840, navigation, header, close),
    );
  }

  Widget _scaffold(bool wide, bool navigation, Widget? header, Widget? close) {
    final ready = widget.client.state == ChatClientState.ready;
    final thread = ready && _selected != null;
    final setup = ready && !thread && _settingUp && _config != null;
    final body = _messengerBody(
      ready: ready,
      thread: thread,
      setup: setup,
      header: header,
      close: close,
    );
    return Scaffold(
      backgroundColor: _theme.colorScheme.surface,
      bottomNavigationBar: navigation && !wide
          ? _navigation(rail: false)
          : null,
      body: navigation && wide
          ? Row(
              children: [
                SafeArea(right: false, child: _navigation(rail: true)),
                VerticalDivider(
                  width: 1,
                  color: _theme.colorScheme.outlineVariant,
                ),
                Expanded(child: body),
              ],
            )
          : body,
    );
  }

  Widget _messengerBody({
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
                    ? _threadList()
                    : setup
                    ? _ConversationSetup(
                        key: ValueKey('setup-${_setupStatus != null}'),
                        config: _config!,
                        strings: _strings,
                        submitting: _creating,
                        status: _setupStatus,
                        onSubmit: (preChat, routing) => unawaited(
                          _create(preChat: preChat, routingChoiceId: routing),
                        ),
                      )
                    : switch (_visibleSection) {
                        ChatMessengerSection.home => _homeView(close),
                        ChatMessengerSection.messages => _conversationList(),
                        ChatMessengerSection.help => _HelpSection(
                          key: ValueKey('help-$_helpGeneration'),
                          controller: _help!,
                          strings: _strings,
                          initialRoute: _helpEntry,
                          onOpenLink: widget.onOpenLink,
                          contacting: _creating,
                          onContactSupport: _startConversation,
                          close: close,
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
                      if (event is ScrollStartNotification)
                        _scrollingMessages = true;
                      if (event is ScrollEndNotification)
                        _scrollingMessages = false;
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
                constraints: const BoxConstraints(maxWidth: 720),
                child: body,
              ),
            ),
          );
        },
      ),
    );
  }

  /// Bottom bar on phones; a rail on expanded widths (Material guidance).
  Widget _navigation({required bool rail}) {
    final unread = _unread?.isStale == false ? _unread?.count ?? 0 : 0;
    Widget messagesIcon(IconData icon) => unread > 0
        ? Badge(label: Text(_strings.number(unread)), child: Icon(icon))
        : Icon(icon);
    final sections = [
      ChatMessengerSection.home,
      ChatMessengerSection.messages,
      if (_helpAvailable || _visibleSection == ChatMessengerSection.help)
        ChatMessengerSection.help,
    ];
    void select(int index) {
      final section = sections[index];
      if (section == _visibleSection) return;
      if (section == ChatMessengerSection.help) {
        _openHelp(const _HelpRoot());
      } else {
        setState(() => _section = section);
      }
    }

    if (rail) {
      return NavigationRail(
        selectedIndex: sections.indexOf(_visibleSection),
        labelType: NavigationRailLabelType.all,
        onDestinationSelected: select,
        destinations: [
          NavigationRailDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home_rounded),
            label: Text(_text(ChatText.home)),
          ),
          NavigationRailDestination(
            icon: messagesIcon(Icons.chat_bubble_outline_rounded),
            selectedIcon: messagesIcon(Icons.chat_bubble_rounded),
            label: Text(_text(ChatText.messages)),
          ),
          if (sections.contains(ChatMessengerSection.help))
            NavigationRailDestination(
              icon: const Icon(Icons.help_outline_rounded),
              selectedIcon: const Icon(Icons.help_rounded),
              label: Text(_text(ChatText.help)),
            ),
        ],
      );
    }
    return NavigationBar(
      selectedIndex: sections.indexOf(_visibleSection),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      onDestinationSelected: select,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home_rounded),
          label: _text(ChatText.home),
        ),
        NavigationDestination(
          icon: messagesIcon(Icons.chat_bubble_outline_rounded),
          selectedIcon: messagesIcon(Icons.chat_bubble_rounded),
          label: _text(ChatText.messages),
          tooltip: unread > 0
              ? '${_text(ChatText.messages)}, ${_strings.unread(unread)}'
              : null,
        ),
        if (sections.contains(ChatMessengerSection.help))
          NavigationDestination(
            icon: const Icon(Icons.help_outline_rounded),
            selectedIcon: const Icon(Icons.help_rounded),
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

    return ListView(
      key: const ValueKey('messenger-home'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        // One Column: it hit-tests the shifted child first, so the part of the
        // card drawn over the intro still receives taps. (List children are
        // hit-tested by their unshifted layout position.)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _HomeIntro(
              brand: _BrandMark(
                name: _appName,
                logoUrl: _config?.appearance.logoUrl,
              ),
              name: _appName,
              status: _ConnectionStatus(
                widget.client.connectionState,
                _strings.status(widget.client.connectionState.name),
              ),
              title: _config?.headerTitle ?? _text(ChatText.homeTitle),
              body: _text(
                _helpAvailable
                    ? ChatText.homeWelcomeHelp
                    : ChatText.homeWelcome,
              ),
              close: close,
            ),
            // The rest of Home rises 36 px so the contact card overlaps the
            // intro's lower edge by a fixed amount at any text size, as on the web.
            Transform.translate(
              offset: const Offset(0, -36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: contact,
                  ),
                  if (recent != null) ...[
                    _HomeSectionTitle(_text(ChatText.recentConversation)),
                    _ConversationCard(
                      key: ValueKey(recent.id),
                      title: subject(recent),
                      subtitle: [
                        _strings.status(recent.status),
                        if (_date(recent.updatedAt).isNotEmpty)
                          _date(recent.updatedAt),
                      ].join(' · '),
                      unread: unread(recent),
                      brand: _BrandMark(
                        name: _appName,
                        logoUrl: _config?.appearance.logoUrl,
                        size: 32,
                      ),
                      onTap: () => _enterConversation(recent),
                    ),
                  ],
                  if (_helpAvailable) ...[
                    _HomeSectionTitle(_text(ChatText.findAnswer)),
                    _homeHelp(),
                  ],
                  if (links.isNotEmpty) ...[
                    _HomeSectionTitle(_text(ChatText.helpfulLinks)),
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
      ],
    );
  }

  /// Home's "Find an answer": search into Help, three featured articles (or
  /// topics when none are featured) and "View all articles".
  Widget _homeHelp() {
    final help = _help!;
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
              count: _strings.articles(collection.articleCount),
              onTap: () => _openHelp(_HelpListingRoute(collection)),
            ),
          );
        }
      }
      rows.add(
        _HelpArticleRow(
          title: _text(ChatText.viewAllArticles),
          excerpt: '',
          onTap: () => _openHelp(const _HelpListingRoute(null)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: _HelpSearchField(
                controller: _homeSearch,
                hint: _text(ChatText.searchHelp),
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
                        '${_text(ChatText.helpUnavailable)} · '
                        '${_text(ChatText.tryAgain)}',
                      ),
                    )
            else
              for (final row in rows) ...[
                Divider(height: 1, color: scheme.outlineVariant),
                row,
              ],
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
    setState(() {
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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _creating ? null : _startConversation,
              child: Text(
                _creating
                    ? _text(ChatText.starting)
                    : _text(ChatText.startConversation),
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
          brand: _BrandMark(
            name: _appName,
            logoUrl: _config?.appearance.logoUrl,
            size: 32,
          ),
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
      child: ListView.builder(
        key: ValueKey('message-history-$_selected'),
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _messages.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _awaitingReply
                ? _ThreadNote(_text(ChatText.awaitingReply), live: true)
                : const SizedBox.shrink();
          }
          if (index == _messages.length + 1) return _pagination(messages: true);
          final message = _messages[index - 1];
          return SizedBox(
            key: _readTiles.putIfAbsent(message.id, () => GlobalKey()),
            child: _messageTile(message),
          );
        },
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
        constraints: const BoxConstraints(maxHeight: 180),
        child: ListView(
          shrinkWrap: true,
          children: _uploads.map(_uploadTile).toList(),
        ),
      ),
    if (widget.client.typingAgents(_selected!).isNotEmpty)
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
    if (_contactEligible)
      _ContactPrompt(
        key: ValueKey('contact-$_epoch-$_selected'),
        client: widget.client,
        conversationId: _selected!,
        strings: _strings,
      ),
    Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: _composer(),
    ),
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
                  AppLifecycleState.resumed))
        return;
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
