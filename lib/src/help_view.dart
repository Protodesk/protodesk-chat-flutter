part of 'chat_screen.dart';

// Help Center inside the messenger, mirroring the web widget's Help tab:
// root (search, topics, hand-off) → collection or all articles → article.

sealed class _HelpRoute {
  const _HelpRoute();
}

final class _HelpRoot extends _HelpRoute {
  const _HelpRoot([this.query = '']);
  final String query;
}

final class _HelpListingRoute extends _HelpRoute {
  const _HelpListingRoute(this.collection);

  /// Null lists every article.
  final ChatHelpCollection? collection;
}

final class _HelpArticleRoute extends _HelpRoute {
  _HelpArticleRoute(this.id, this.slug, this.article);
  final String id, slug;
  final Future<ChatHelpArticle> article;
}

const _rtlLanguages = {'ar', 'fa', 'he', 'ku', 'ps', 'ur'};
const _languageNames = {
  'en': 'English',
  'id': 'Bahasa Indonesia',
  'ms': 'Bahasa Melayu',
  'th': 'ไทย',
  'vi': 'Tiếng Việt',
  'zh': '中文',
  'ja': '日本語',
  'ko': '한국어',
  'es': 'Español',
  'fr': 'Français',
  'de': 'Deutsch',
  'pt': 'Português',
  'it': 'Italiano',
  'nl': 'Nederlands',
  'ar': 'العربية',
  'tr': 'Türkçe',
  'hi': 'हिन्दी',
};

const _languageFlags = {
  'ar': '🇸🇦',
  'cs': '🇨🇿',
  'de': '🇩🇪',
  'en': '🇬🇧',
  'es': '🇪🇸',
  'fa': '🇮🇷',
  'fr': '🇫🇷',
  'he': '🇮🇱',
  'hi': '🇮🇳',
  'hu': '🇭🇺',
  'id': '🇮🇩',
  'it': '🇮🇹',
  'ja': '🇯🇵',
  'ko': '🇰🇷',
  'ms': '🇲🇾',
  'nl': '🇳🇱',
  'pl': '🇵🇱',
  'pt': '🇧🇷',
  'ro': '🇷🇴',
  'ru': '🇷🇺',
  'sv': '🇸🇪',
  'th': '🇹🇭',
  'tr': '🇹🇷',
  'uk': '🇺🇦',
  'vi': '🇻🇳',
  'zh': '🇨🇳',
};
Widget _languageFlag(String locale) => ExcludeSemantics(
  child: Text(
    _languageFlags[locale.split('-').first.toLowerCase()] ?? '🌐',
    style: const TextStyle(
      fontSize: 18,
      fontFamilyFallback: ['Apple Color Emoji', 'Noto Color Emoji'],
    ),
  ),
);

String _languageName(String locale) =>
    _languageNames[locale.split('-').first.toLowerCase()] ??
    locale.toUpperCase();

class _HelpSection extends StatefulWidget {
  const _HelpSection({
    super.key,
    required this.controller,
    required this.strings,
    required this.onContactSupport,
    required this.contacting,
    this.initialRoute = const _HelpRoot(),
    this.onOpenLink,
    this.close,
    required this.expanded,
    this.onExpand,
  });
  final ChatHelpController controller;
  final ChatLocalizations strings;
  final VoidCallback? onContactSupport;
  final bool contacting;
  final _HelpRoute initialRoute;
  final Future<void> Function(Uri url)? onOpenLink;
  final Widget? close;
  final bool expanded;
  final ValueChanged<bool>? onExpand;

  @override
  State<_HelpSection> createState() => _HelpSectionState();
}

class _HelpSectionState extends State<_HelpSection> {
  // A directly opened article sits above the Help home so Back stays in Help.
  late final List<_HelpRoute> _stack = [
    if (widget.initialRoute is! _HelpRoot) const _HelpRoot(),
    widget.initialRoute,
  ];
  late final _search = TextEditingController(
    text: switch (widget.initialRoute) {
      _HelpRoot(:final query) => query,
      _ => '',
    },
  );
  final _scroll = ScrollController();
  StreamSubscription<void>? _changes;
  Timer? _debounce;
  late String _query = _search.text.trim();
  String? _locale;

  ChatHelpController get _help => widget.controller;
  String _text(ChatText key) => widget.strings.text(key);

  @override
  void initState() {
    super.initState();
    _locale = _help.locale;
    _changes = _help.changes.listen((_) {
      if (!mounted) return;
      // A locale switch invalidates every cached route. The first load only
      // learns the locale, so a directly opened article must survive it.
      if (_help.manifest != null && _help.locale != _locale) {
        final switched = _locale != null;
        _locale = _help.locale;
        if (switched) {
          _debounce?.cancel();
          _search.clear();
          _query = '';
          _stack
            ..clear()
            ..add(const _HelpRoot());
        }
      }
      setState(() {});
    });
    unawaited(_help.load());
    final route = widget.initialRoute;
    if (route is _HelpListingRoute) _startListing(route);
    if (_query.length >= 2) _onQuery(_query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_changes?.cancel());
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  ChatHelpListing _listingFor(_HelpListingRoute route) =>
      _help.listing(collectionId: route.collection?.id);

  void _startListing(_HelpListingRoute route) {
    final listing = _listingFor(route);
    if (!listing.isLoaded && !listing.isLoading) unawaited(listing.loadMore());
  }

  void _push(_HelpRoute route) {
    if (route is _HelpListingRoute) _startListing(route);
    setState(() => _stack.add(route));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _openArticle(String id, String slug) =>
      _push(_HelpArticleRoute(id, slug, _help.article(id)));

  void _pop() {
    if (_stack.length > 1) {
      if (widget.expanded) widget.onExpand?.call(false);
      setState(() => _stack.removeLast());
    }
  }

  void _onQuery(String value) {
    _debounce?.cancel();
    final query = value.trim();
    setState(() => _query = query);
    if (query.length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final listing = _help.listing(query: query);
      if (!listing.isLoaded && !listing.isLoading) {
        unawaited(listing.loadMore());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = _stack.last;
    final manifest = _help.manifest;
    final title = _text(ChatText.helpCenter);
    final articleUrl = route is _HelpArticleRoute && widget.onOpenLink != null
        ? manifest?.articleUrl(route.slug)
        : null;
    final locale = manifest?.activeLocale ?? '';
    return PopScope(
      canPop: _stack.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FutureBuilder<ChatHelpArticle>(
            key: ValueKey(route),
            future: route is _HelpArticleRoute ? route.article : null,
            builder: (context, snapshot) => _MessengerHeader(
              title: route is _HelpArticleRoute
                  ? snapshot.data?.title ?? title
                  : title,
              leading: _stack.length > 1
                  ? IconButton(
                      tooltip: _text(ChatText.backToHelp),
                      onPressed: _pop,
                      icon: const ChatWidgetIcon(ChatGlyph.back, size: 22),
                    )
                  : null,
              actions: [
                if (route is _HelpArticleRoute && widget.onExpand != null)
                  IconButton(
                    tooltip: _text(
                      widget.expanded
                          ? ChatText.restoreArticle
                          : ChatText.expandArticle,
                    ),
                    onPressed: () => widget.onExpand!(!widget.expanded),
                    icon: ChatWidgetIcon(
                      widget.expanded
                          ? ChatGlyph.restoreArticle
                          : ChatGlyph.expandArticle,
                      size: 18,
                    ),
                  ),
                if (articleUrl != null)
                  IconButton(
                    tooltip: _text(ChatText.openInHelpCenter),
                    onPressed: () => unawaited(
                      widget.onOpenLink!(articleUrl).catchError((Object _) {}),
                    ),
                    icon: const ChatWidgetIcon(ChatGlyph.openArticle, size: 22),
                  ),
                ?widget.close,
              ],
            ),
          ),
          Expanded(
            child: Directionality(
              // Help content and labels follow the resolved Help Center language.
              textDirection:
                  _rtlLanguages.contains(locale.split('-').first.toLowerCase())
                  ? TextDirection.rtl
                  : locale.isNotEmpty
                  ? TextDirection.ltr
                  : Directionality.of(context),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: theme.colorScheme.onSurface),
                child: RawScrollbar(
                  controller: _scroll,
                  thickness: 3,
                  thumbVisibility: true,
                  thumbColor: ChatBrandColors.resolve(theme).borderStrong,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: SingleChildScrollView(
                      key: ValueKey(
                        'help-${_stack.length}-${route.runtimeType}',
                      ),
                      controller: _scroll,
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth:
                                widget.expanded && route is _HelpArticleRoute
                                ? 756
                                : 376,
                          ),
                          child: switch (route) {
                            _HelpRoot() => _root(),
                            _HelpListingRoute() => _listingPage(route),
                            _HelpArticleRoute() => _articlePage(route),
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _root() {
    final theme = Theme.of(context);
    final manifest = _help.manifest;
    final searching = _query.length >= 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      manifest?.name ?? _text(ChatText.helpCenter),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontVariations: const [FontVariation.weight(750)],
                        height: 1.15,
                        letterSpacing: -.45,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      _text(ChatText.helpCenterDescription),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (manifest != null && manifest.availableLocales.length > 1)
                _languageMenu(manifest),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: _HelpSearchField(
            controller: _search,
            hint: _text(ChatText.searchHelp),
            clearLabel: _text(ChatText.clearSearch),
            onChanged: _onQuery,
            onSubmitted: _onQuery,
          ),
        ),
        const SizedBox(height: 8),
        if (_query.isNotEmpty && !searching)
          _HelpNote(_text(ChatText.typeMoreToSearch))
        else if (searching)
          _searchResults()
        else
          _rootBody(),
      ],
    );
  }

  Widget _languageMenu(
    ChatHelpCenterManifest manifest,
  ) => PopupMenuButton<String>(
    tooltip:
        '${_text(ChatText.language)}: ${_languageName(manifest.activeLocale)}',
    initialValue: manifest.activeLocale,
    onSelected: (locale) => unawaited(_help.selectLocale(locale)),
    itemBuilder: (_) => [
      for (final locale in manifest.availableLocales)
        PopupMenuItem(
          height: 36,
          value: locale,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _languageFlag(locale),
              const SizedBox(width: 8),
              Flexible(child: Text(_languageName(locale))),
            ],
          ),
        ),
    ],
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minHeight:
            Theme.of(context).materialTapTargetSize ==
                MaterialTapTargetSize.padded
            ? 48
            : 40,
        maxWidth: min(154, MediaQuery.sizeOf(context).width * .38),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 8),
            _languageFlag(manifest.activeLocale),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _languageName(manifest.activeLocale),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const Icon(Icons.expand_more_rounded, size: 18),
            const SizedBox(width: 8),
          ],
        ),
      ),
    ),
  );

  Widget _rootBody() {
    final theme = Theme.of(context);
    final manifest = _help.manifest;
    if (manifest == null) {
      if (_help.isUnavailable) {
        return _HelpEmpty(
          _text(ChatText.helpUnavailable),
          _text(ChatText.helpUnavailableDescription),
        );
      }
      if (_help.error != null) return _retry(() => _help.load(refresh: true));
      return const _HelpSkeleton(rows: 4);
    }
    final roots = manifest.rootCollections;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 5),
          // Wraps under the heading when large text makes the button wide.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                _text(ChatText.browseHelp).toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  letterSpacing: .88,
                  fontWeight: FontWeight.w700,
                ),
              ),
              OutlinedButton(
                onPressed: () => _push(const _HelpListingRoute(null)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(48, 32),
                  textStyle: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                  foregroundColor: theme.colorScheme.secondary,
                  side: BorderSide(color: theme.colorScheme.outlineVariant),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(_text(ChatText.viewAllArticles))),
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (roots.isEmpty)
          _HelpNote(_text(ChatText.noPublishedArticles))
        else
          _HelpGroup(
            children: [
              for (final collection in roots)
                _HelpCollectionRow(
                  key: ValueKey('help-collection-${collection.id}'),
                  collection: collection,
                  count: widget.strings.articles(collection.articleCount),
                  onTap: () => _push(_HelpListingRoute(collection)),
                ),
            ],
          ),
        _handoff(),
      ],
    );
  }

  Widget _searchResults() {
    final listing = _help.listing(query: _query);
    if (!listing.isLoaded && listing.error == null) {
      return const _HelpSkeleton(rows: 4);
    }
    final label = listing.articles.isEmpty
        ? ChatText.noSearchResults
        : ChatText.searchResults;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (listing.isLoaded)
          _HelpNote(
            listing.articles.isEmpty
                ? '${_text(label)} “$_query”'
                : '${_text(label)}: “$_query”',
          ),
        ..._articles(
          listing,
          empty: _HelpEmpty(
            _text(ChatText.noSearchResults),
            _text(ChatText.noSearchResultsDescription),
          ),
        ),
        _handoff(),
      ],
    );
  }

  Widget _listingPage(_HelpListingRoute route) {
    final theme = Theme.of(context);
    final collection = route.collection;
    final children = collection == null
        ? const <ChatHelpCollection>[]
        : _help.manifest?.childCollections(collection.id) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  collection?.name ?? _text(ChatText.allArticles),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontVariations: const [FontVariation.weight(750)],
                    height: 1.15,
                    letterSpacing: -.45,
                  ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                collection?.description.isNotEmpty == true
                    ? collection!.description
                    : _text(ChatText.browseSupportArticles),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  height: 1.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        if (children.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _HelpGroup(
              children: [
                for (final child in children)
                  _HelpCollectionRow(
                    collection: child,
                    count: widget.strings.articles(child.articleCount),
                    onTap: () => _push(_HelpListingRoute(child)),
                  ),
              ],
            ),
          ),
        ..._articles(
          _listingFor(route),
          empty: _HelpNote(
            _text(
              collection == null
                  ? ChatText.noPublishedArticles
                  : ChatText.noCollectionArticles,
            ),
          ),
        ),
        _handoff(),
      ],
    );
  }

  List<Widget> _articles(ChatHelpListing listing, {required Widget empty}) {
    if (!listing.isLoaded) {
      if (listing.error != null) return [_retry(listing.loadMore)];
      return const [_HelpSkeleton(rows: 3)];
    }
    if (listing.articles.isEmpty) return [empty];
    return [
      _HelpGroup(
        children: [
          for (final article in listing.articles)
            _HelpArticleRow(
              key: ValueKey('help-article-${article.id}'),
              title: article.title,
              excerpt: article.excerpt,
              onTap: () => _openArticle(article.id, article.slug),
            ),
        ],
      ),
      if (listing.error != null)
        _retry(listing.loadMore)
      else if (listing.hasMore)
        Center(
          child: TextButton(
            onPressed: listing.isLoading
                ? null
                : () => unawaited(listing.loadMore()),
            child: Text(_text(ChatText.loadMore)),
          ),
        ),
    ];
  }

  Widget _articlePage(_HelpArticleRoute route) => FutureBuilder(
    key: ValueKey(route.id),
    future: route.article,
    builder: (context, snapshot) {
      final article = snapshot.data;
      if (article != null && route.slug.isEmpty) {
        // Opened by ID: learn the slug for "Open in Help Center".
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final index = _stack.indexOf(route);
          if (!mounted || index < 0) return;
          setState(
            () => _stack[index] = _HelpArticleRoute(
              route.id,
              article.slug,
              route.article,
            ),
          );
        });
      }
      if (article == null) {
        if (snapshot.hasError) {
          return _retry(() async {
            final retried = _HelpArticleRoute(
              route.id,
              route.slug,
              _help.article(route.id),
            );
            setState(() => _stack[_stack.length - 1] = retried);
          });
        }
        return const _HelpSkeleton(rows: 6, article: true);
      }
      return _HelpArticleBody(
        article: article,
        strings: widget.strings,
        onOpenLink: widget.onOpenLink,
        onRelated: (related) => _openArticle(related.id, related.slug),
        handoff: _handoff(),
      );
    },
  );

  Widget _retry(Future<void> Function() retry) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        _ChatStatus(
          _text(ChatText.helpUnavailable),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        TextButton(
          onPressed: () => unawaited(retry()),
          child: Text(_text(ChatText.tryAgain)),
        ),
      ],
    ),
  );

  Widget _handoff() => widget.onContactSupport == null
      ? const SizedBox.shrink()
      : _HelpHandoff(
          title: _text(ChatText.stillNeedHelp),
          body: _text(ChatText.stillNeedHelpDescription),
          action: widget.contacting
              ? _text(ChatText.starting)
              : _text(ChatText.contactSupport),
          onPressed: widget.contacting ? null : widget.onContactSupport,
        );
}

class _HelpSearchField extends StatelessWidget {
  const _HelpSearchField({
    required this.controller,
    required this.hint,
    required this.clearLabel,
    this.home = false,
    required this.onChanged,
    required this.onSubmitted,
  });
  final TextEditingController controller;
  final String hint, clearLabel;
  final bool home;
  final ValueChanged<String> onChanged, onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(home ? 12 : 13);
    final field = ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) => TextField(
        controller: controller,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontSize: home ? 12 : 13),
        inputFormatters: [LengthLimitingTextInputFormatter(120)],
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            fontSize: home ? 12 : 13,
            color: home ? scheme.onSurfaceVariant : ChatTheme.faint(theme),
          ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(
              color: home
                  ? scheme.outlineVariant
                  : ChatBrandColors.resolve(theme).borderStrong,
            ),
          ),
          suffixIconConstraints: const BoxConstraints(minHeight: 46),
          suffixIcon: Padding(
            padding: const EdgeInsetsDirectional.only(end: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.text.isNotEmpty)
                  IconButton(
                    style: IconButton.styleFrom(
                      minimumSize: Size.square(home ? 31 : 36),
                    ),
                    tooltip: clearLabel,
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
                IconButton(
                  style: IconButton.styleFrom(
                    minimumSize: Size.square(home ? 31 : 36),
                  ),
                  tooltip: hint,
                  icon: ChatWidgetIcon(ChatGlyph.search, size: home ? 18 : 19),
                  onPressed: () => onSubmitted(controller.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return home
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: .05),
                  blurRadius: 16,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: field,
          )
        : field;
  }
}

/// A bordered group of rows separated by hairlines.
class _HelpGroup extends StatelessWidget {
  const _HelpGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Material(
        color: scheme.surface,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              children[i],
              Divider(height: 1, color: scheme.outlineVariant),
            ],
          ],
        ),
      ),
    );
  }
}

class _RowArrow extends StatelessWidget {
  const _RowArrow({required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Text(
      Directionality.of(context) == TextDirection.rtl ? '‹' : '›',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
        fontSize: size,
        height: 1,
        fontWeight: FontWeight.w400,
        fontVariations: const [FontVariation.weight(450)],
        color: color,
      ),
    ),
  );
}

class _HelpCollectionRow extends StatelessWidget {
  const _HelpCollectionRow({
    super.key,
    required this.collection,
    required this.count,
    required this.onTap,
  });
  final ChatHelpCollection collection;
  final String count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final description = collection.description.isEmpty
        ? count
        : collection.description;
    return InkWell(
      onTap: onTap,
      child: Semantics(
        button: true,
        label: '${collection.name}, $count',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      collection.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${collection.articleCount}',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontVariations: const [FontVariation.weight(650)],
                ),
              ),
              const SizedBox(width: 7),
              _RowArrow(size: 24, color: scheme.onSurface),
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpArticleRow extends StatelessWidget {
  const _HelpArticleRow({
    super.key,
    required this.title,
    required this.excerpt,
    required this.onTap,
    this.inlineArrow = false,
    this.browse = false,
  });
  final String title, excerpt;
  final bool inlineArrow, browse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: !inlineArrow
              ? 61
              : browse &&
                    theme.materialTapTargetSize != MaterialTapTargetSize.padded
              ? 42
              : 48,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: inlineArrow && !browse ? 5 : 4,
            vertical: browse
                ? 9
                : inlineArrow
                ? 10
                : 11.6,
          ),
          child: Row(
            mainAxisSize: browse ? MainAxisSize.min : MainAxisSize.max,
            children: [
              Flexible(
                fit: inlineArrow ? FlexFit.loose : FlexFit.tight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: inlineArrow ? 12 : 13,
                        fontWeight: inlineArrow && !browse
                            ? FontWeight.w600
                            : FontWeight.w700,
                        fontVariations: inlineArrow && !browse
                            ? const [FontVariation.weight(650)]
                            : null,
                      ),
                    ),
                    if (excerpt.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      _ArticleExcerpt(excerpt),
                    ],
                  ],
                ),
              ),
              SizedBox(width: browse ? 4 : 12),
              SizedBox(
                width: inlineArrow ? (browse ? 18 : 27) : null,
                child: _RowArrow(
                  size: inlineArrow ? 19 : 24,
                  color: inlineArrow
                      ? scheme.onSurfaceVariant
                      : scheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chrome clamps the excerpt at the last line break before adding an ellipsis.
class _ArticleExcerpt extends StatelessWidget {
  const _ArticleExcerpt(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall!.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 2,
        )..layout(maxWidth: bounds.maxWidth);
        var display = text;
        if (painter.didExceedMaxLines) {
          final line = painter.computeLineMetrics().last;
          final position = painter.getPositionForOffset(
            Offset(line.left + line.width / 2, line.baseline),
          );
          final end = painter.getLineBoundary(position).end;
          display = '${text.substring(0, end).trimRight()}…';
        }
        painter.dispose();
        return Text(
          display,
          semanticsLabel: text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

class _HelpHandoff extends StatelessWidget {
  const _HelpHandoff({
    required this.title,
    required this.body,
    required this.action,
    required this.onPressed,
  });
  final String title, body, action;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(18, 24, 18, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              height: 1.5,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              textStyle: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                fontVariations: const [FontVariation.weight(750)],
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

class _HelpNote extends StatelessWidget {
  const _HelpNote(this.text, {this.title = false});
  final String text;
  final bool title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(
        text,
        style: title
            ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)
            : theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
      ),
    );
  }
}

class _HelpEmpty extends StatelessWidget {
  const _HelpEmpty(this.title, this.body);
  final String title, body;

  @override
  Widget build(BuildContext context) => _EmptyThread(title, body);
}

/// Static placeholders shaped like the final rows (no shimmer).
class _HelpSkeleton extends StatelessWidget {
  const _HelpSkeleton({required this.rows, this.article = false});
  final int rows;
  final bool article;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Semantics(
      label: MaterialLocalizations.of(context).refreshIndicatorSemanticLabel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (article) bar(width * 0.8, 26),
                for (var i = 0; i < rows; i++) ...[
                  bar(width * (i.isEven ? 0.6 : 0.45), 14),
                  bar(width * (article ? 0.95 : 0.85), 12),
                  const SizedBox(height: 6),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Article: title, excerpt, "On this page", Markdown body, related, hand-off.
class _HelpArticleBody extends StatefulWidget {
  const _HelpArticleBody({
    required this.article,
    required this.strings,
    required this.onRelated,
    required this.handoff,
    this.onOpenLink,
  });
  final ChatHelpArticle article;
  final ChatLocalizations strings;
  final Future<void> Function(Uri url)? onOpenLink;
  final ValueChanged<ChatHelpRelatedArticle> onRelated;
  final Widget handoff;

  @override
  State<_HelpArticleBody> createState() => _HelpArticleBodyState();
}

class _HelpArticleBodyState extends State<_HelpArticleBody> {
  late ChatHelpDocument _document = ChatHelpDocument.parse(
    widget.article.bodyMarkdown,
  );
  bool _contentsOpen = false;
  final _anchors = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant _HelpArticleBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.article.bodyMarkdown != widget.article.bodyMarkdown) {
      _document = ChatHelpDocument.parse(widget.article.bodyMarkdown);
      _anchors.clear();
      _contentsOpen = false;
    }
  }

  void _jump(String id) {
    final target = _anchors[id]?.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(
        target,
        alignment: 0.05,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final article = widget.article;
    final outline = _document.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (article.collection != null) ...[
                Text(
                  article.collection!.name.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color:
                        theme.materialTapTargetSize ==
                            MaterialTapTargetSize.padded
                        ? scheme.onPrimaryContainer
                        : scheme.primary,
                    fontSize: 10,
                    height: 1.15,
                    fontWeight: FontWeight.w700,
                    fontVariations: const [FontVariation.weight(750)],
                    letterSpacing: .8,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Semantics(
                header: true,
                child: Text(
                  article.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontVariations: const [FontVariation.weight(750)],
                    fontSize: 23,
                    letterSpacing: -.805,
                    height: 1.2,
                  ),
                ),
              ),
              if (article.excerpt.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  article.excerpt,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    height: 1.55,
                    letterSpacing: 0,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (outline.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 0),
            child: Material(
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    button: true,
                    expanded: _contentsOpen,
                    child: InkWell(
                      onTap: () =>
                          setState(() => _contentsOpen = !_contentsOpen),
                      child: Container(
                        alignment: AlignmentDirectional.centerStart,
                        constraints: BoxConstraints(
                          minHeight:
                              theme.materialTapTargetSize ==
                                  MaterialTapTargetSize.padded
                              ? 48
                              : 46,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            RotatedBox(
                              quarterTurns: _contentsOpen
                                  ? 1
                                  : Directionality.of(context) ==
                                        TextDirection.rtl
                                  ? 2
                                  : 0,
                              child: const Icon(Icons.play_arrow, size: 12),
                            ),
                            Flexible(
                              child: Text(
                                widget.strings.text(ChatText.onThisPage),
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_contentsOpen) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Divider(height: 1, color: scheme.outlineVariant),
                    ),
                    for (final heading in outline)
                      Semantics(
                        link: true,
                        child: InkWell(
                          onTap: () => _jump(heading.id!),
                          child: Container(
                            alignment: AlignmentDirectional.centerStart,
                            constraints: BoxConstraints(
                              minHeight:
                                  theme.materialTapTargetSize ==
                                      MaterialTapTargetSize.padded
                                  ? 48
                                  : 26,
                            ),
                            padding: EdgeInsetsDirectional.fromSTEB(
                              heading.level >= 3 ? 26 : 14,
                              9,
                              14,
                              2,
                            ),
                            child: Text(
                              heading.text,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 24, 18, 0),
          child: _HelpMarkdown(
            document: _document,
            anchors: _anchors,
            onOpenLink: widget.onOpenLink,
            strings: widget.strings,
          ),
        ),
        if (article.relatedArticles.isNotEmpty) ...[
          _HelpNote(widget.strings.text(ChatText.relatedArticles), title: true),
          _HelpGroup(
            children: [
              for (final related in article.relatedArticles)
                _HelpArticleRow(
                  key: ValueKey('help-related-${related.id}'),
                  title: related.title,
                  excerpt: related.excerpt,
                  onTap: () => widget.onRelated(related),
                ),
            ],
          ),
        ],
        widget.handoff,
      ],
    );
  }
}

/// Renders a parsed Compact Help document with Material text styles.
/// Links open through the host adapter; without one they render as text.
class _HelpMarkdown extends StatefulWidget {
  const _HelpMarkdown({
    required this.document,
    required this.anchors,
    required this.strings,
    this.onOpenLink,
  });
  final ChatHelpDocument document;
  final Map<String, GlobalKey> anchors;
  final ChatLocalizations strings;
  final Future<void> Function(Uri url)? onOpenLink;

  @override
  State<_HelpMarkdown> createState() => _HelpMarkdownState();
}

class _HelpMarkdownState extends State<_HelpMarkdown> {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  List<InlineSpan> _inline(List<ChatHelpInline> content, TextStyle? base) {
    final scheme = Theme.of(context).colorScheme;
    final link = ChatBrandColors.resolve(Theme.of(context)).foreground;
    return [
      for (final item in content)
        switch (item) {
          ChatHelpText(:final value) => TextSpan(text: value),
          ChatHelpStrong(:final value) => TextSpan(
            text: value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          ChatHelpEmphasis(:final value) => TextSpan(
            text: value,
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
          ChatHelpInlineCode(:final value) => TextSpan(
            text: value,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (base?.fontSize ?? 14) * 0.92,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
          ChatHelpLink(:final label, :final url) => TextSpan(
            text: label,
            style: TextStyle(
              color: link,
              decoration: TextDecoration.underline,
              decorationColor: link,
            ),
            recognizer: widget.onOpenLink == null
                ? null
                : (TapGestureRecognizer()
                        ..onTap = () => unawaited(
                          widget.onOpenLink!(url).catchError((Object _) {}),
                        ))
                      .also(_recognizers.add),
          ),
          ChatHelpImage() => WidgetSpan(child: _HelpImage(item)),
        },
    ];
  }

  Widget _rich(List<ChatHelpInline> content, TextStyle? style) =>
      Text.rich(TextSpan(style: style, children: _inline(content, style)));

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 13,
      letterSpacing: 0,
      height: 1.68,
      color: theme.brightness == Brightness.light
          ? const Color(0xff3f3f46)
          : scheme.onSurface,
    );
    final blocks = <Widget>[];
    for (final block in widget.document.blocks) {
      switch (block) {
        case ChatHelpHeading(:final content, :final id):
          final style = theme.textTheme.titleMedium?.copyWith(
            fontSize: 15,
            height: 1.35,
            letterSpacing: 0,
            fontWeight: FontWeight.w700,
          );
          blocks.add(
            Padding(
              key: id == null
                  ? null
                  : widget.anchors.putIfAbsent(id, GlobalKey.new),
              padding: const EdgeInsets.only(top: 23),
              child: Semantics(header: true, child: _rich(content, style)),
            ),
          );
        case ChatHelpParagraph(:final content):
          blocks.add(
            blocks.isEmpty
                ? _rich(content, body)
                : _spaced(_rich(content, body)),
          );
        case ChatHelpQuote(:final content):
          blocks.add(
            _spaced(
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Color.alphaBlend(
                    scheme.primary.withValues(alpha: 0.06),
                    scheme.surface,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: _rich(
                  content,
                  body?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          );
        case ChatHelpList(:final ordered, :final items):
          blocks.add(
            _spaced(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < items.length; i++)
                    Padding(
                      padding: EdgeInsetsDirectional.only(
                        start: 8,
                        top: i == 0 ? 0 : 5,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: items[i].checked != null
                                ? 22
                                : ordered
                                ? (i + 1).toString().length * 8.0 + 8
                                : 12,
                            child: switch (items[i].checked) {
                              true => Icon(
                                Icons.check_box_rounded,
                                size: 18,
                                color: ChatBrandColors.resolve(
                                  Theme.of(context),
                                ).foreground,
                                semanticLabel: '✓',
                              ),
                              false => Icon(
                                Icons.check_box_outline_blank_rounded,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                              null when ordered => Text(
                                '${i + 1}.',
                                style: body,
                              ),
                              null => SizedBox(
                                height:
                                    MediaQuery.textScalerOf(context).scale(13) *
                                    1.68,
                                child: Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: body?.color,
                                    ),
                                    child: SizedBox.square(
                                      dimension: MediaQuery.textScalerOf(
                                        context,
                                      ).scale(4),
                                    ),
                                  ),
                                ),
                              ),
                            },
                          ),
                          Expanded(child: _rich(items[i].content, body)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        case ChatHelpTable(:final headers, :final rows):
          final cell = theme.textTheme.bodyMedium;
          blocks.add(
            _spaced(
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder.all(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  children: [
                    TableRow(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLow,
                      ),
                      children: [
                        for (final header in headers)
                          _cell(
                            _rich(
                              header,
                              cell?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                      ],
                    ),
                    for (final row in rows)
                      TableRow(
                        children: [
                          for (final value in row) _cell(_rich(value, cell)),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        case ChatHelpCode(:final value, :final language):
          blocks.add(
            _spaced(
              _HelpCode(
                value: value,
                label: language == 'mermaid'
                    ? widget.strings.text(ChatText.diagramSource)
                    : language,
                strings: widget.strings,
              ),
            ),
          );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }

  Widget _spaced(Widget child) =>
      Padding(padding: const EdgeInsets.only(top: 11.5), child: child);

  Widget _cell(Widget child) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 260),
    child: Padding(padding: const EdgeInsets.all(10), child: child),
  );
}

extension<T> on T {
  T also(void Function(T) action) {
    action(this);
    return this;
  }
}

class _HelpImage extends StatelessWidget {
  const _HelpImage(this.image);
  final ChatHelpImage image;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final max = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : MediaQuery.sizeOf(context).width - 40;
      final width = switch (image.size) {
        ChatHelpImageSize.small => max * 0.4,
        ChatHelpImageSize.medium => max * 0.7,
        ChatHelpImageSize.full => max,
        ChatHelpImageSize.original => null,
      };
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: max),
            child: Image.network(
              image.url.toString(),
              width: width,
              fit: BoxFit.contain,
              semanticLabel: image.alt.isEmpty ? null : image.alt,
              excludeFromSemantics: image.alt.isEmpty,
              cacheWidth: (max * MediaQuery.devicePixelRatioOf(context))
                  .round()
                  .clamp(1, 2400),
              errorBuilder: (_, _, _) => Container(
                padding: const EdgeInsets.all(10),
                color: scheme.surfaceContainerLow,
                child: Text(
                  image.alt,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Escaped code with an optional language label and a copy action.
class _HelpCode extends StatefulWidget {
  const _HelpCode({required this.value, required this.strings, this.label});
  final String value;
  final String? label;
  final ChatLocalizations strings;

  @override
  State<_HelpCode> createState() => _HelpCodeState();
}

class _HelpCodeState extends State<_HelpCode> {
  Timer? _reset;
  bool _copied = false;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  widget.label ?? '',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // Icon-only so it fits beside the label at any text size; the
                // tooltip and live status carry the words.
                IconButton(
                  onPressed: _copy,
                  tooltip: widget.strings.text(
                    _copied ? ChatText.copied : ChatText.copyCode,
                  ),
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.copy_rounded,
                    size: 18,
                  ),
                ),
                if (_copied)
                  _ChatStatus(
                    widget.strings.text(ChatText.copied),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text(
              widget.value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
