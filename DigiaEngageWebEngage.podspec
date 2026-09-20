Pod::Spec.new do |s|
  s.name             = 'DigiaEngageWebEngage'
  s.version          = '1.0.0'
  s.summary          = 'Digia Engage WebEngage plugin for iOS.'
  s.description      = <<-DESC
    Routes WebEngage in-app campaigns into Digia Engage.
  DESC
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/digia_engage_webengage_ios'
  s.license          = { :type => 'BSL-1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/digia_engage_webengage_ios.git',
    :tag => s.version.to_s
  }
  s.platform         = :ios, '15.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/**/*.swift'

  # WebEngage is a DEPENDENCY here, not vendored — deliberately unlike Package.swift.
  #
  # Package.swift bundles Frameworks/WebEngage.xcframework as a .binaryTarget because
  # WebEngage ships CocoaPods-only and SPM has no other way to resolve the import. That
  # reasoning does not carry over to CocoaPods, where the pod exists: vendoring a second
  # copy collides with the one every real WebEngage app already has, and `pod install`
  # fails outright —
  #
  #     The 'Pods-<App>' target has frameworks with conflicting names: webengage.xcframework
  #
  # react-native-webengage declares `'WebEngage', '>= 6.16.1'`, so that is the floor here.
  # Range, never an exact pin: the host app and its RN wrapper must be able to agree on one
  # version with us.
  s.dependency 'WebEngage', '>= 6.16.1'

  # A range, never an exact pin: CocoaPods has to satisfy every podspec in the
  # host app's graph at once, and two exact pins on the same pod deadlock
  # resolution outright — the clevertap_plugin 3.8.1 failure mode.
  s.dependency 'DigiaEngage', '~> 3.14'
end
