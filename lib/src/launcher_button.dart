import 'package:flutter/material.dart';

import 'theme.dart';
import 'widget_icon.dart';

/// Website chat launcher for a host Scaffold's floatingActionButton.
/// Pass a localized label and a callback that opens the client's messenger.
class ChatLauncherButton extends StatelessWidget {
  const ChatLauncherButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.color = ChatTheme.protodeskPrimary,
    this.unread = 0,
    this.expanded = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final Color color;
  final int unread;
  final bool expanded;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Badge(
      isLabelVisible: !expanded && unread > 0,
      label: Text(unread > 99 ? '99+' : '$unread'),
      backgroundColor: const Color(0xffdc2626),
      textColor: Colors.white,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3d18181b),
              offset: Offset(0, 12),
              blurRadius: 32,
            ),
          ],
        ),
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: IconButton(
            onPressed: onPressed,
            style: IconButton.styleFrom(fixedSize: const Size.square(56)),
            color:
                MediaQuery.highContrastOf(context) &&
                    color.computeLuminance() > .18
                ? Colors.black
                : Colors.white,
            icon: expanded
                ? const Icon(Icons.close, size: 25)
                : const ChatWidgetIcon(ChatGlyph.launcher, size: 25),
          ),
        ),
      ),
    ),
  );
}
