Pod::Spec.new do |s|
  s.name = 'protodesk_chat'
  s.version = '0.1.0'
  s.summary = 'Protected native attachment storage for Protodesk Chat.'
  s.description = s.summary
  s.homepage = 'https://protodesk.io'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'Protodesk'
  s.source = { :path => '.' }
  # Shared with the Swift package so CocoaPods and SwiftPM build the same code.
  s.source_files = 'protodesk_chat/Sources/protodesk_chat/**/*.swift'
  s.resource_bundles = {
    'protodesk_chat_privacy' => ['protodesk_chat/Sources/protodesk_chat/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
