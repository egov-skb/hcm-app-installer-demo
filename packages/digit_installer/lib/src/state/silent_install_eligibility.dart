/// Whether the fully silent (no confirmation dialog) install path is
/// actually usable right now. Queried proactively by hosts using
/// [InstallMode.silentDeviceOwner] so [DigitInstaller.install] never has to
/// "try silent, catch failure" — it falls back to the confirm flow cleanly
/// whenever this isn't [SilentInstallEligible].
sealed class SilentInstallEligibility {
  const SilentInstallEligibility();
}

final class SilentInstallEligible extends SilentInstallEligibility {
  const SilentInstallEligible();
}

final class SilentInstallNotDeviceOwner extends SilentInstallEligibility {
  const SilentInstallNotDeviceOwner();
}

final class SilentInstallUnsupportedApiLevel extends SilentInstallEligibility {
  const SilentInstallUnsupportedApiLevel(this.currentSdkInt);
  final int currentSdkInt;
}

final class SilentInstallNotAndroid extends SilentInstallEligibility {
  const SilentInstallNotAndroid();
}
