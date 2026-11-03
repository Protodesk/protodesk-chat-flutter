import 'package:flutter/widgets.dart';

/// Lets a host entry point reuse the already-open destination across launchers.
abstract interface class MessengerLocation {
  bool get showingHelp;
  String? get conversationId;
  String? get helpArticleId;
}

/// Set by the presentation route; an embedded messenger is visible by default.
class MessengerVisibility extends InheritedWidget {
  const MessengerVisibility({
    super.key,
    required this.visible,
    required super.child,
  });
  final bool visible;
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MessengerVisibility>()
          ?.visible ??
      true;
  @override
  bool updateShouldNotify(MessengerVisibility oldWidget) =>
      visible != oldWidget.visible;
}
