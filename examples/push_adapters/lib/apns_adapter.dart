import 'package:protodesk_chat/protodesk_chat.dart';

/// Forward from the host's existing AppDelegate/channel. No delegate swizzling,
/// replacement notification handler, token disk cache, or permission prompt.
final class ApnsChatAdapter {
  ApnsChatAdapter(this.binding);
  final ChatPushRegistrationBinding binding; // provider: apns, platform: ios
  Future<void> didRegister({required String hexToken, required bool allowed}) =>
      binding.update(token: hexToken, permissionGranted: allowed);
  Future<void> permissionRevoked() => binding.update(permissionGranted: false);
  Future<void> dispose() => binding.dispose();
}
