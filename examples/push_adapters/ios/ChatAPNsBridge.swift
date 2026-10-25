import Flutter
import UserNotifications

// Own this helper in the HOST app. Forward existing AppDelegate/notification
// callbacks to it; it never installs a UIApplication/UNUserNotification delegate.
final class ChatAPNsBridge {
    private let channel: FlutterMethodChannel
    private var token: String?
    private var pendingTap: [AnyHashable: Any]?
    private var tapAt: Date?
    private var dartReady = false

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "host.protodesk/apns", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            switch call.method {
            case "snapshot":
                self.dartReady = true
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    DispatchQueue.main.async {
                        var snapshot: [String: Any] = [
                            "allowed": settings.authorizationStatus == .authorized ||
                                settings.authorizationStatus == .provisional ||
                                settings.authorizationStatus == .ephemeral
                        ]
                        if let token = self.token { snapshot["token"] = token }
                        result(snapshot)
                    }
                }
            case "takeInitialTap":
                let fresh = self.tapAt.map { Date().timeIntervalSince($0) < 120 } ?? false
                result(fresh ? self.pendingTap : nil)
                self.pendingTap = nil
                self.tapAt = nil
            default: result(FlutterMethodNotImplemented)
            }
        }
    }
    // Call on main thread from didRegisterForRemoteNotificationsWithDeviceToken.
    func didRegister(deviceToken: Data) {
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
        if dartReady { channel.invokeMethod("registrationChanged", arguments: nil) }
    }
    // Call for the user's default open action, NOT delivery or dismiss actions.
    // The host must still call its existing completion handler exactly once.
    func didOpen(userInfo: [AnyHashable: Any]) {
        guard userInfo["protodesk"] != nil else { return }
        if dartReady {
            pendingTap = nil; tapAt = nil
            channel.invokeMethod("opened", arguments: userInfo)
        }
        else { pendingTap = userInfo; tapAt = Date() }
    }
}
