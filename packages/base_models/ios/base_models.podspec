#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint base_models.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'base_models'
  s.version          = '0.0.1'
  s.summary          = 'Shared on-device model store (App Group container).'
  s.description      = <<-DESC
Shared on-device model store (App Group container).
                       DESC
  s.homepage         = 'https://github.com/shashank2577/baseapp'
  s.license          = { :type => 'Proprietary' }
  s.author           = { 'Base platform' => 'dev@baseplatform.dev' }
  s.source           = { :path => '.' }
  s.source_files = 'base_models/Sources/base_models/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'base_models_privacy' => ['base_models/Sources/base_models/PrivacyInfo.xcprivacy']}
end
