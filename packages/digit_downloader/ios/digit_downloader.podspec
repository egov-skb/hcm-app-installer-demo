#
# UNVERIFIED: written without access to Xcode/macOS — see the package
# README's "iOS background downloads" section before relying on this.
#
Pod::Spec.new do |s|
  s.name             = 'digit_downloader'
  s.version          = '0.0.1'
  s.summary          = 'A generic background resumable/chunked download engine.'
  s.description      = <<-DESC
Native iOS side of BackgroundDownloadMode.systemManaged: a background
URLSession-backed chunked download engine with resumable state and
progress notifications, mirroring the pure-Dart engine's default behavior.
                       DESC
  s.homepage         = 'https://justunknown.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'justunknown.com' => 'hello@justunknown.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
