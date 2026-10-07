// Web has no install concept at all: `DigitInstaller.checkForUpdate` (a plain
// HTTP GET) works regardless of platform registration, and `download()`/
// `install()` are guarded directly at the facade level via `kIsWeb` (see
// digit_installer.dart) rather than through a registered platform class.
//
// There is deliberately no `web:` entry in pubspec.yaml's plugin platforms —
// this project's bundled Flutter tooling requires a `pluginClass`/JS-interop
// shape for web plugin entries that a pure dartPluginClass-only
// implementation (like every other platform here) doesn't satisfy. Since web
// never needs any registered platform implementation in the first place
// (the facade's kIsWeb guards run before `DigitInstallerPlatform.instance` is
// ever touched for install-related calls), omitting the entry is correct,
// not a workaround.
