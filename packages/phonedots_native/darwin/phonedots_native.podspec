# CocoaPods fallback. LiteRT-LM and Desert Ant ship as Swift packages only, so
# under CocoaPods the bridges compile without them and report the engines as
# unavailable. Swift Package Manager (Package.swift) is what releases use.
Pod::Spec.new do |s|
  s.name             = 'phonedots_native'
  s.version          = '0.1.0'
  s.summary          = "PhoneDots' native bridges on iOS and macOS."
  s.homepage         = 'https://github.com/Shashank2577/PhoneDots'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'PhoneDots' => 'dev@phonedots.ai' }
  s.source           = { :path => '.' }
  s.source_files     = 'phonedots_native/Sources/phonedots_native/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '18.0'
  s.osx.deployment_target = '14.0'
  s.swift_version = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
