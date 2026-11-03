part of 'chat_screen.dart';

// Presentational pieces of the messenger. Layout mirrors the web livechat
// widget (protodesk-web/src/widget) using Material colour roles, so host and
// Chat App brands stay legible in light and dark.

/// Configured HTTPS logo, with the website's P mark as its fallback.
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.logoUrl, this.size = 36});
  final Uri? logoUrl;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaled = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.4);
    final extent = scaled.scale(size);
    final initial = Center(
      child: Text(
        'P',
        style: TextStyle(
          color: scheme.onPrimaryContainer,
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
          color: logoUrl == null ? scheme.primaryContainer : Colors.transparent,
          border: Border.all(
            color: logoUrl == null
                ? Color.lerp(scheme.surface, scheme.primary, .18)!
                : Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(extent * 0.30),
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
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 8)],
              if (brand != null) ...[brand!, const SizedBox(width: 8)],
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

/// The header and composer stay in place while the first conversation loads.
class _OpeningChat extends StatelessWidget {
  const _OpeningChat({required this.label, this.close});
  final String label;
  final Widget? close;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget block(double width, double height, double radius) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 64,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 44),
                block(36, 36, 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      block(152, 9, 5),
                      const SizedBox(height: 7),
                      block(104, 7, 4),
                    ],
                  ),
                ),
                ?close,
              ],
            ),
          ),
          Expanded(
            child: Semantics(
              label: label,
              liveRegion: true,
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Container(
                  margin: const EdgeInsets.fromLTRB(18, 22, 18, 0),
                  width: 58,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: const BorderRadiusDirectional.only(
                      topStart: Radius.circular(6),
                      topEnd: Radius.circular(16),
                      bottomStart: Radius.circular(16),
                      bottomEnd: Radius.circular(16),
                    ),
                  ),
                  child: const _TypingDots(),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
            child: Column(
              children: [
                Container(
                  height: 48,
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 7, 7, 7),
                  decoration: BoxDecoration(
                    border: Border.all(color: scheme.outlineVariant),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Row(
                    children: [
                      block(20, 20, 7),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: block(154, 9, 5),
                        ),
                      ),
                      const SizedBox(width: 8),
                      block(34, 34, 10),
                    ],
                  ),
                ),
                const SizedBox(height: 9),
                block(108, 7, 4),
              ],
            ),
          ),
        ],
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
      ChatConnectionState.connected => const Color(0xff4ade80),
      ChatConnectionState.disconnected => const Color(0xffa1a1aa),
      _ => const Color(0xfffbbf24),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: dot,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: dot.withValues(alpha: .2), spreadRadius: 2),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: _ChatStatus(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              height: 1.3,
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
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: const FontWeight(750),
              height: 1.15,
              letterSpacing: -.45,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            body,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              height: 1.5,
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
    this.recent = false,
    this.semanticsLabel,
  });
  final String title, subtitle;
  final Widget brand;
  final bool recent;
  final String? unread, semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      shape: recent
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: scheme.outlineVariant),
            )
          : Border(bottom: BorderSide(color: scheme.outlineVariant)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Semantics(
          button: true,
          label: semanticsLabel,
          excludeSemantics: semanticsLabel != null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 68),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: recent ? 12 : 4,
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
                ],
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
    final foreground = customer
        ? scheme.onPrimary
        : system
        ? scheme.onSurfaceVariant
        : scheme.onSurface;
    final bubble = Container(
      padding: system
          ? const EdgeInsets.fromLTRB(13, 11, 13, 8)
          : const EdgeInsets.fromLTRB(14, 12, 14, 9),
      decoration: system
          ? null
          : BoxDecoration(
              color: customer ? scheme.primary : scheme.surfaceContainer,
              borderRadius: BorderRadiusDirectional.only(
                topStart: Radius.circular(customer ? 16 : 6),
                topEnd: Radius.circular(customer ? 6 : 16),
                bottomStart: const Radius.circular(16),
                bottomEnd: const Radius.circular(16),
              ),
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
                  label!.toUpperCase(),
                  semanticsLabel: label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontSize: 10,
                    letterSpacing: .9,
                    fontWeight: FontWeight.w700,
                    color: foreground,
                  ),
                ),
              ),
            ?child,
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                alignment: AlignmentDirectional.centerEnd,
                constraints: const BoxConstraints(minHeight: 14),
                child: Text(
                  meta,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: customer
                        ? foreground.withValues(
                            alpha:
                                theme.materialTapTargetSize ==
                                    MaterialTapTargetSize.padded
                                ? 1
                                : .68,
                          )
                        : ChatTheme.faint(theme),
                    fontSize: 9,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
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
                  640,
                ),
              ),
              child: meta.isEmpty ? bubble : IntrinsicWidth(child: bubble),
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
      fontSize: 10,
      height: 1.18,
      letterSpacing: 0,
      color: ChatTheme.faint(theme),
      fontWeight: FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          text: '$prefix ',
          children: [
            TextSpan(
              text: 'Protodesk',
              style: style?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
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
        padding: const EdgeInsets.only(top: 16),
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
                  meta: '',
                  footer: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 2, top: 6),
                    child: Text(
                      widget.meta,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w400,
                        color: ChatTheme.faint(theme),
                      ),
                    ),
                  ),
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

/// Background painted in the scrollable Home content, as in the website frame.
class _HomeBackdrop extends CustomPainter {
  const _HomeBackdrop(this.brand, this.canvas);
  final Color brand, canvas;

  @override
  void paint(Canvas c, Size size) {
    final rect = Offset.zero & Size(size.width, 340);
    c.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(canvas, brand, .04)!, canvas],
        ).createShader(rect),
    );
    c.drawCircle(
      Offset(size.width * .04, 52),
      54,
      Paint()..color = brand.withValues(alpha: .13),
    );
    c.drawCircle(
      Offset(size.width * 1.08, 212),
      118,
      Paint()..color = brand.withValues(alpha: .09),
    );
  }

  @override
  bool shouldRepaint(_HomeBackdrop old) =>
      brand != old.brand || canvas != old.canvas;
}

class _HomeIntro extends StatelessWidget {
  const _HomeIntro({
    required this.brand,
    required this.name,
    required this.status,
    required this.title,
    required this.body,
    required this.eyebrow,
    this.close,
  });
  final Widget brand, status;
  final Widget? close;
  final String eyebrow;
  final String name, title, body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .28),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Color.lerp(scheme.outlineVariant, scheme.primary, .28)!,
        ),
      ),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 42),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    brand,
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          status,
                        ],
                      ),
                    ),
                    if (close != null)
                      Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: scheme.surface.withValues(alpha: .55),
                              border: Border.all(color: scheme.outlineVariant),
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 40,
                            ),
                            child: close!,
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          child: Text(
                            eyebrow.toUpperCase(),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: ChatBrandColors.readable(
                                scheme.primary,
                                scheme.primaryContainer,
                                theme.brightness == Brightness.dark,
                              ).foreground,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.26,
                              fontSize: 9,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: const FontWeight(750),
                            height: 1.08,
                            letterSpacing: -.91,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 285),
                        child: Text(
                          body,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.secondary,
                            fontSize: 12.5,
                            height: 1.55,
                          ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: .10),
            blurRadius: 34,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Color.lerp(scheme.outlineVariant, scheme.primary, .16)!,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: true,
            label: semanticsLabel,
            excludeSemantics: semanticsLabel != null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 74),
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
                        border: Border.all(
                          color: scheme.primary.withValues(alpha: .14),
                        ),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: ChatWidgetIcon(
                        ChatGlyph.message,
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
                    Container(
                      width: 27,
                      height: 27,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.chevron_right,
                        size: 19,
                        color: scheme.onSurfaceVariant,
                      ),
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
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 9),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: const FontWeight(750),
            fontSize: 12,
            height: 1.2,
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
    return Column(
      children: [
        for (final link in links)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Material(
              color: scheme.surface,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Semantics(
                link: true,
                hint: hint,
                child: InkWell(
                  onTap: () => onOpen(link.url),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          theme.materialTapTargetSize ==
                              MaterialTapTargetSize.padded
                          ? 48
                          : 42,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              link.label,
                              style: theme.textTheme.labelMedium,
                            ),
                          ),
                          Icon(
                            Icons.open_in_new,
                            size: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Filled actions from the pre-chat form and Messages list.
class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.label,
    required this.onPressed,
    this.setup = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool setup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(setup ? 11 : 12);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          if (onPressed != null)
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: .16),
              offset: Offset(0, setup ? 8 : 7),
              blurRadius: setup ? 20 : 18,
            ),
        ],
      ),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: Size.fromHeight(setup ? 45 : 44),
          padding: EdgeInsets.symmetric(
            horizontal: setup ? 15 : 16,
            vertical: 10,
          ),
          shape: RoundedRectangleBorder(borderRadius: radius),
          textStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 13,
            letterSpacing: 0,
            fontWeight: setup ? const FontWeight(750) : FontWeight.w700,
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
