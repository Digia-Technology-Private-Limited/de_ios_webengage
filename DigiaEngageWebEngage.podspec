Pod::Spec.new do |s|
  s.name             = 'DigiaEngageWebEngage'
  s.version          = '2.0.0'
  s.summary          = 'Digia Engage WebEngage plugin for iOS.'
  s.description      = <<-DESC
    Routes WebEngage in-app campaigns into Digia Engage.
  DESC
  s.homepage         = 'https://github.com/Digia-Technology-Private-Limited/de_ios_webengage'
  s.license          = { :type => 'BSL-1.1', :file => 'LICENSE' }
  s.author           = { 'Digia Engg' => 'engg@digia.tech' }
  s.source           = {
    :git => 'https://github.com/Digia-Technology-Private-Limited/de_ios_webengage.git',
    :tag => s.version.to_s
  }
  s.platform         = :ios, '15.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/**/*.swift'

  # WebEngage is a DEPENDENCY here, never vendored: a second copy collides with the one
  # every real WebEngage app already has, and `pod install` fails. Pinned to 7.1.0, the
  # version Package.swift and the Flutter plugin use, so every stack runs one WebEngage.
  s.dependency 'WebEngage', '7.1.0'

  # DigiaEngage takes a range, not an exact pin: CocoaPods has to satisfy every podspec in the
  # host app's graph at once, and two exact pins on the same pod deadlock
  # resolution outright — the clevertap_plugin 3.8.1 failure mode.
  s.dependency 'DigiaEngage', '~> 4.0'
end
