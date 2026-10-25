import Flutter
import Foundation
import UIKit

public final class ProtodeskChatPlugin: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "protodesk.chat.attachment-files")
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "protodesk_chat/attachment_files", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ProtodeskChatPlugin(), channel: channel)
  }
  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "available" { result(UIApplication.shared.isProtectedDataAvailable); return }
    worker.async {
      do { let value = try self.perform(call); DispatchQueue.main.async { result(value) } }
      catch { DispatchQueue.main.async { result(FlutterError(code: "attachment_storage_unavailable", message: "Protected attachment storage unavailable", details: nil)) } }
    }
  }
  private func checked(_ value: Any?, handle: Bool = false) throws -> String {
    guard let s = value as? String, s.range(of: handle ? "^[a-f0-9-]{36}$" : "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileReadInvalidFileName) }
    return s
  }
  private func protect(_ url: URL) throws {
    var target = url
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try target.setResourceValues(values)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.protectionKey] as? FileProtectionType == .complete,
      try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw CocoaError(.fileWriteNoPermission) }
  }
  private func directory(_ url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey:FileProtectionType.complete])
    try protect(url); return url
  }
  private func remove(_ url: URL) throws {
    do { try FileManager.default.removeItem(at: url) }
    catch let error as NSError {
      if error.domain != NSCocoaErrorDomain || error.code != NSFileNoSuchFileError { throw error }
    }
  }
  private func perform(_ call: FlutterMethodCall) throws -> Any? {
    let args = call.arguments as? [String:Any] ?? [:]
    let scope = try checked(args["scope"]), partition = try checked(args["partition"])
    let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let base = try directory(support.appendingPathComponent("protodesk_chat_attachments", isDirectory: true))
    let root = try directory(base.appendingPathComponent(scope, isDirectory: true))
    let dir = try directory(root.appendingPathComponent(partition, isDirectory: true))
    if call.method == "purge" { try remove(dir); return nil }
    if call.method == "retain" {
      guard let list = args["handles"] as? [String], list.count <= 10 else { throw CocoaError(.fileReadCorruptFile) }
      let handles = try Set(list.map { try checked($0, handle: true) })
      for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        if folder.lastPathComponent != partition { try remove(folder); continue }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
          if !handles.contains(file.lastPathComponent) { try remove(file) }
        }
      }
      return nil
    }
    let handle = try checked(args["handle"], handle: true), file = dir.appendingPathComponent(handle)
    if call.method == "delete" { try remove(file); return nil }
    if call.method == "write" {
      guard let data = (args["bytes"] as? FlutterStandardTypedData)?.data, !data.isEmpty, data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileWriteInvalidFileName) }
      try data.write(to: file, options: [.atomic, .completeFileProtection])
      try protect(file)
      let writer = try FileHandle(forWritingTo: file); defer { try? writer.close() }; try writer.synchronize()
      return nil
    }
    if call.method == "read" {
      let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
      guard let size = attrs[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 * 1024 * 1024,
        attrs[.protectionKey] as? FileProtectionType == .complete,
        try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else { throw CocoaError(.fileReadCorruptFile) }
      let data = try Data(contentsOf: file)
      guard data.count == size.intValue else { throw CocoaError(.fileReadCorruptFile) }
      return FlutterStandardTypedData(bytes: data)
    }
    throw CocoaError(.featureUnsupported)
  }
}
