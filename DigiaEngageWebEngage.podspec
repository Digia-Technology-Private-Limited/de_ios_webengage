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

  # WebEngage is vendored, not a dependency: Package.swift bundles
  # Frameworks/WebEngage.xcframework as a binaryTarget so SPM can resolve the
  # import without the host adding WebEngage itself. Mirror that here rather
  # than declaring `s.dependency 'WebEngage'` — a host app that also pulls in
  # WebEngage (CocoaPods or SPM) links two copies of the same symbols and the
  # linker fails. This podspec is the only place WebEngage should be declared.
  s.vendored_frameworks = 'Frameworks/WebEngage.xcframework'

  # A range, never an exact pin: CocoaPods has to satisfy every podspec in the
  # host app's graph at once, and two exact pins on the same pod deadlock
  # resolution outright — the clevertap_plugin 3.8.1 failure mode.
  s.dependency 'DigiaEngage', '~> 3.14'
end
