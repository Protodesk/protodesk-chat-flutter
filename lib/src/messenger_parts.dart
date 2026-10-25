part of 'chat_screen.dart';

// Presentational pieces of the messenger. Layout mirrors the web livechat
// widget (protodesk-web/src/widget) using Material colour roles, so host and
// Chat App brands stay legible in light and dark.

/// Logo when the Chat App has an HTTPS logo, otherwise its initial.
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.name, this.logoUrl, this.size = 36});
  final String name;
  final Uri? logoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaled = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    final extent = scaled.scale(size);
    final initial = Center(
      child: Text(
        name.isEmpty ? 'P' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: scheme.onPrimary,
          fontWeight: FontWeight.w700,
          fontSize: extent * 0.45,
          height: 1,
        ),
        textScaler: TextScaler.noScaling,
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: extent,
        height: extent,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(extent * 0.28),
        ),
        child: logoUrl == null
            ? initial
            : Image.network(
                logoUrl.toString(),
                fit: BoxFit.cover,
                cacheWidth: (extent * 3).round(),
                errorBuilder: (_, _, _) => initial,
              ),
      ),
    );
  }
}

/// Section or thread header: optional back, brand and status, then actions.
class _MessengerHeader extends StatelessWidget {
  const _MessengerHeader({
    required this.title,
    this.status,
    this.brand,
    this.leading,
    this.actions = const [],
  });
  final String title;
  final Widget? status, brand, leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: Padding(
          padding: EdgeInsetsDirectional.only(
            start: leading == null ? 16 : 4,
            end: 4,
            top: 6,
            bottom: 6,
          ),
          child: Row(
            children: [
              ?leading,
              if (brand != null) ...[brand!, const SizedBox(width: 10)],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ?status,
                  ],
                ),
              ),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// Connection status with a coloured dot; the text is a live region.
class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus(this.state, this.label);
  final ChatConnectionState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dot = switch (state) {
      ChatConnectionState.connected => const Color(0xff16a34a),
      ChatConnectionState.disconnected => scheme.error,
      _ => scheme.outline,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: _ChatStatus(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.title, this.body);
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// A conversation row: brand mark, subject, "Status · date" and unread count.
class _ConversationCard extends StatelessWidget {
  const _ConversationCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.brand,
    required this.onTap,
    this.unread,
    this.semanticsLabel,
  });
  final String title, subtitle;
  final Widget brand;
  final String? unread, semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: unread == null ? scheme.surface : scheme.primaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: semanticsLabel,
            excludeSemantics: semanticsLabel != null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    brand,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: unread == null
                                  ? FontWeight.w500
                                  : FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (unread != null) ...[
                      const SizedBox(width: 8),
                      _CountBadge(unread!),
                    ],
                    const SizedBox(width: 4),
                    Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.chevron_left_rounded
                          : Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onPrimary),
      ),
    );
  }
}

enum _BubbleKind { customer, agent, system }

/// One message bubble. Customer messages sit at the end in the brand colour;
/// support messages at the start on a muted surface; notices are centred.
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.kind,
    required this.meta,
    this.child,
    this.label,
    this.footer,
  });
  final _BubbleKind kind;
  final Widget? child, footer;
  final String? label;
  final String meta;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final customer = kind == _BubbleKind.customer;
    final system = kind == _BubbleKind.system;
    final foreground = system ? scheme.onSurfaceVariant : scheme.onSurface;
    // The mobile app's bubbles: the sender's own messages carry a light brand
    // tint and border; the other side sits on a raised neutral surface.
    final dark = theme.brightness == Brightness.dark;
    final bubble = Container(
      padding: system
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : const EdgeInsets.all(12),
      decoration: system
          ? BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(999),
            )
          : BoxDecoration(
              color: customer
                  ? Color.alphaBlend(
                      scheme.primary.withValues(alpha: dark ? 0.14 : 0.10),
                      scheme.surface,
                    )
                  : scheme.surfaceContainerLow,
              border: Border.all(
                color: customer
                    ? scheme.primary.withValues(alpha: 0.20)
                    : scheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground),
        child: Column(
          crossAxisAlignment: system
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  label!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
            ?child,
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                meta,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: system
            ? CrossAxisAlignment.center
            : customer
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (constraints.maxWidth * (system ? 0.9 : 0.82)).clamp(
                  0,
                  560,
                ),
              ),
              child: bubble,
            ),
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// Three pulsing dots; static when animations are disabled.
class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return SizedBox(
      height: 16,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Opacity(
                  opacity: _controller.isAnimating
                      ? 0.35 +
                            0.65 *
                                (1 -
                                    ((_controller.value * 3 - i) % 3)
                                        .clamp(0, 1)
                                        .toDouble())
                      : 0.6,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Centred, muted guidance inside the thread.
class _ThreadNote extends StatelessWidget {
  const _ThreadNote(this.text, {this.live = false});
  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Center(
        child: live
            ? _ChatStatus(text, style: style)
            : Text(text, style: style, textAlign: TextAlign.center),
      ),
    );
  }
}

class _EmptyThread extends StatelessWidget {
  const _EmptyThread(this.title, this.body);
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 300),
        margin: const EdgeInsets.fromLTRB(24, 48, 24, 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PoweredBy extends StatelessWidget {
  const _PoweredBy(this.prefix);
  final String prefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          text: '$prefix ',
          children: [
            TextSpan(
              text: 'Protodesk',
              style: style?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        style: style,
        textAlign: TextAlign.center,
      ),
    );
  }
}

/// The Chat App greeting as the first support bubble. Like the web widget it
/// "types" briefly before appearing, unless animations are disabled.
class _GreetingBubble extends StatefulWidget {
  const _GreetingBubble({
    required this.text,
    required this.meta,
    required this.semanticsLabel,
  });
  final String text, meta, semanticsLabel;

  @override
  State<_GreetingBubble> createState() => _GreetingBubbleState();
}

class _GreetingBubbleState extends State<_GreetingBubble> {
  Timer? _timer;
  bool _typing = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_typing || _timer != null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _typing = false;
    } else {
      _timer = Timer(const Duration(milliseconds: 520), () {
        if (mounted) setState(() => _typing = false);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: AnimatedSwitcher(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          child: _typing
              ? const _MessageBubble(
                  key: ValueKey('greeting-typing'),
                  kind: _BubbleKind.agent,
                  meta: '',
                  child: _TypingDots(),
                )
              : _MessageBubble(
                  key: const ValueKey('greeting'),
                  kind: _BubbleKind.agent,
                  meta: widget.meta,
                  child: Text(
                    widget.text,
                    semanticsLabel: widget.semanticsLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      height: 1.45,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Home's branded intro: identity row, heading and supporting copy on a soft
/// brand tint, with room at the bottom for the overlapping contact card.
/// A signed-in user's avatar, or their initial when there is no image.
class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.name, this.url});
  final String name;
  final Uri? url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const extent = 32.0;
    final initial = Center(
      child: Text(
        name.characters.first.toUpperCase(),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: 14,
          height: 1,
        ),
        textScaler: TextScaler.noScaling,
      ),
    );
    return ExcludeSemantics(
      child: Container(
        width: extent,
        height: extent,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: url == null
            ? initial
            : Image.network(
                url.toString(),
                fit: BoxFit.cover,
                cacheWidth: (extent * 3).round(),
                errorBuilder: (_, _, _) => initial,
              ),
      ),
    );
  }
}

class _HomeIntro extends StatelessWidget {
  const _HomeIntro({
    required this.brand,
    required this.name,
    required this.status,
    required this.title,
    required this.body,
    this.avatar,
    this.close,
  });
  final Widget brand, status;
  final Widget? avatar, close;
  final String name, title, body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tint = Color.alphaBlend(
      scheme.primary.withValues(alpha: 0.07),
      scheme.surface,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.20)),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 52),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    brand,
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          status,
                        ],
                      ),
                    ),
                    if (avatar != null) ...[
                      const SizedBox(width: 8),
                      avatar!,
                      if (close != null) const SizedBox(width: 4),
                    ],
                    ?close,
                  ],
                ),
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        body,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Home's primary action: continue the active conversation or start one.
class _HomeContactCard extends StatelessWidget {
  const _HomeContactCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.unread,
    this.semanticsLabel,
  });
  final String title, subtitle;
  final String? unread, semanticsLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Flat, hairline-bordered card, as in the mobile app.
    return DecoratedBox(
      decoration: const BoxDecoration(),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: semanticsLabel,
            excludeSemantics: semanticsLabel != null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.chat_bubble_outline_rounded,
                        size: 20,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (unread != null) ...[
                      const SizedBox(width: 8),
                      _CountBadge(unread!),
                    ],
                    const SizedBox(width: 4),
                    Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.chevron_left_rounded
                          : Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small section title inside Home.
class _HomeSectionTitle extends StatelessWidget {
  const _HomeSectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Configured HTTPS links, opened by the host's [ChatMessenger.onOpenLink].
class _HomeLinks extends StatelessWidget {
  const _HomeLinks({
    required this.links,
    required this.onOpen,
    required this.hint,
  });
  final List<ChatWidgetLink> links;
  final void Function(Uri url) onOpen;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
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
          children: [
            for (var i = 0; i < links.length; i++) ...[
              if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
              Semantics(
                link: true,
                hint: hint,
                child: InkWell(
                  onTap: () => onOpen(links[i].url),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              links[i].label,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
