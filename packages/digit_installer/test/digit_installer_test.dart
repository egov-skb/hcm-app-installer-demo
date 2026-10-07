import 'package:flutter_test/flutter_test.dart';
import 'package:digit_installer/digit_installer.dart';

void main() {
  test('public API is exported from the barrel file', () {
    expect(const UpdateIdle(), isA<UpdateState>());
    expect(const SilentInstallNotAndroid(), isA<SilentInstallEligibility>());
  });
}
