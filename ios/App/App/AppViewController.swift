import Capacitor

/// nestly_v670/v745: app-local Capacitor plugins are not discovered from packageClassList (that
/// list is generated from installed npm packages), so the documented registration point is a
/// CAPBridgeViewController subclass with `capacitorDidLoad()`.
///
/// This class only does its job if it is the class that is actually instantiated. In this shell
/// the root controller is created in code by SceneDelegate — NOT from Main.storyboard — and v670
/// learned that the hard way: changing the storyboard's class shipped three builds in which this
/// override never ran. SceneDelegate must construct AppViewController(); the storyboard's class
/// is kept in agreement for anyone reading it, but it is not the authority.
class AppViewController: CAPBridgeViewController {
  override open func capacitorDidLoad() {
    bridge?.registerPluginInstance(BiometricCredentialPlugin())
  }
}
