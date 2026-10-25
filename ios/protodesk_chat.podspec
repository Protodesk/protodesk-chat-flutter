Pod::Spec.new do |s|
  s.name = 'protodesk_chat'
  s.version = '0.1.0'
  s.summary = 'Protected native attachment storage for Protodesk Chat.'
  s.description = s.summary
  s.homepage = 'https://protodesk.io'
  s.license = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author = 'Protodesk'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
