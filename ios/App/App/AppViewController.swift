import Capacitor

/// nestly_v670: app-local Capacitor plugins are not discovered from packageClassList (that list
/// is generated from installed npm packages), so the documented registration point is a
/// CAPBridgeViewController subclass. Main.storyboard instantiates this class instead of the
/// Capacitor base class; nothing else about the shell changes.
class AppViewController: CAPBridgeViewController {
  override open func capacitorDidLoad() {
    bridge?.registerPluginInstance(BiometricCredentialPlugin())
  }
}
