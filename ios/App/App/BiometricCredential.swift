import Foundation
import Capacitor
import LocalAuthentication
import Security

/// nestly_v670 — Face ID sign-in for the Peekaa shell.
///
/// WebAuthn passkeys cannot run inside a WKWebView (v669), so the shell offers the native
/// equivalent: the customer's sign-in credential is kept in the iOS Keychain behind a
/// biometry-gated access control, and reading it back IS the Face ID prompt. Deliberate
/// properties of the storage:
///  - `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` — never synced to iCloud, never
///    restored onto another device, gone if the device passcode is removed.
///  - `.biometryCurrentSet` — only the biometrics enrolled at save time unlock it. Adding a
///    new fingerprint or face invalidates the item, so a person who gains enrolment later
///    cannot open the stored credential; the customer just signs in with their password and
///    is offered the setup again.
///  - The refresh token is NOT what is stored. Supabase refresh tokens are single-use and
///    rotate on every refresh, so a stored copy goes stale immediately and replaying it can
///    trip reuse detection. The credential itself is stable and is what iOS AutoFill would
///    hold anyway.
/// The plugin never logs, returns, or retains the secret outside the resolved call.
///
/// nestly_v860 adds a second, unrelated capability to the same plugin: an APP LOCK that
/// re-prompts biometrics (or the device passcode) whenever the app should be gated shut. It
/// never reads or writes the Keychain credential above — it only answers "is this still the
/// device owner?" and persists a plain on/off preference.
@objc(BiometricCredentialPlugin)
public class BiometricCredentialPlugin: CAPPlugin, CAPBridgedPlugin {
  public let identifier = "BiometricCredentialPlugin"
  public let jsName = "BiometricCredential"
  public let pluginMethods: [CAPPluginMethod] = [
    CAPPluginMethod(name: "availability", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "enrolled", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "store", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "retrieve", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "clear", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "authenticate", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "lockPreference", returnType: CAPPluginReturnPromise),
    CAPPluginMethod(name: "setLockPreference", returnType: CAPPluginReturnPromise),
  ]

  private static let service = "asia.peekaa.app.signin"
  private static let account = "customer"
  private static let lockPreferenceKey = "asia.peekaa.app.lock.enabled"

  private func baseQuery() -> [String: Any] {
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
  }

  @objc func availability(_ call: CAPPluginCall) {
    let context = LAContext()
    var error: NSError?
    let available = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    var biometry = "none"
    if available {
      switch context.biometryType {
      case .faceID: biometry = "faceId"
      case .touchID: biometry = "touchId"
      default: biometry = "none"
      }
    }
    call.resolve(["available": available && biometry != "none", "biometry": biometry])
  }

  /// Existence check that must never show a Face ID sheet: the UI is told to fail instead,
  /// so an item that exists-but-needs-auth answers errSecInteractionNotAllowed.
  @objc func enrolled(_ call: CAPPluginCall) {
    DispatchQueue.global(qos: .userInitiated).async {
      var query = self.baseQuery()
      query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
      let status = SecItemCopyMatching(query as CFDictionary, nil)
      call.resolve(["enrolled": status == errSecInteractionNotAllowed || status == errSecSuccess])
    }
  }

  @objc func store(_ call: CAPPluginCall) {
    guard let phone = call.getString("phone"), !phone.isEmpty,
          let password = call.getString("password"), !password.isEmpty,
          phone.utf8.count <= 32, password.utf8.count <= 512 else {
      call.resolve(["status": "invalid"])
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      var accessError: Unmanaged<CFError>?
      guard let access = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
        .biometryCurrentSet,
        &accessError
      ) else {
        call.resolve(["status": "unavailable"])
        return
      }
      guard let secret = try? JSONSerialization.data(withJSONObject: ["phone": phone, "password": password]) else {
        call.resolve(["status": "failed"])
        return
      }
      SecItemDelete(self.baseQuery() as CFDictionary)
      var attributes = self.baseQuery()
      attributes[kSecValueData as String] = secret
      attributes[kSecAttrAccessControl as String] = access
      let status = SecItemAdd(attributes as CFDictionary, nil)
      call.resolve(["status": status == errSecSuccess ? "ok" : "failed"])
    }
  }

  @objc func retrieve(_ call: CAPPluginCall) {
    DispatchQueue.global(qos: .userInitiated).async {
      let context = LAContext()
      context.localizedReason = "Sign in to Peekaa"
      var query = self.baseQuery()
      query[kSecReturnData as String] = true
      query[kSecUseAuthenticationContext as String] = context
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      switch status {
      case errSecSuccess:
        guard let data = result as? Data,
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let phone = parsed["phone"], let password = parsed["password"] else {
          SecItemDelete(self.baseQuery() as CFDictionary)
          call.resolve(["status": "missing"])
          return
        }
        call.resolve(["status": "ok", "phone": phone, "password": password])
      case errSecItemNotFound:
        call.resolve(["status": "missing"])
      case errSecUserCanceled, errSecAuthFailed:
        call.resolve(["status": status == errSecUserCanceled ? "canceled" : "failed"])
      default:
        call.resolve(["status": "failed"])
      }
    }
  }

  @objc func clear(_ call: CAPPluginCall) {
    DispatchQueue.global(qos: .userInitiated).async {
      let status = SecItemDelete(self.baseQuery() as CFDictionary)
      call.resolve(["status": status == errSecSuccess || status == errSecItemNotFound ? "ok" : "failed"])
    }
  }

  // MARK: - App lock (nestly_v860)

  /// The APP LOCK re-auth gate — separate from the biometric SIGN-IN credential above. This
  /// method never touches the Keychain item; it only asks "is this still the device owner?"
  /// and resolves a coarse status, never the underlying error.
  ///
  /// `.deviceOwnerAuthentication` (not `.deviceOwnerAuthenticationWithBiometrics`, which
  /// `availability()` above still uses so it can report which biometry is enrolled) tries
  /// biometrics first but lets iOS fall back to the device passcode on its own — the same
  /// shape banking apps use. Without that fallback, a biometry lockout (too many failed
  /// attempts) or a covered camera/sensor would strand the customer outside their own account
  /// with no way back in; WITH it, a biometry lockout resolves through the passcode instead of
  /// dead-ending the customer.
  @objc func authenticate(_ call: CAPPluginCall) {
    var reason = (call.getString("reason") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if reason.count > 120 { reason = String(reason.prefix(120)) }
    if reason.isEmpty { reason = "Unlock Peekaa" }

    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      call.resolve(["status": "unavailable"])
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evalError in
      if success {
        call.resolve(["status": "ok"])
        return
      }
      // Map to a coarse status only — never log, return, or retain the error text itself.
      switch (evalError as? LAError)?.code {
      case .userCancel, .systemCancel, .appCancel, .userFallback:
        call.resolve(["status": "canceled"])
      case .biometryLockout:
        call.resolve(["status": "lockout"])
      case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
        call.resolve(["status": "unavailable"])
      default:
        call.resolve(["status": "failed"])
      }
    }
  }

  @objc func lockPreference(_ call: CAPPluginCall) {
    call.resolve(["enabled": UserDefaults.standard.bool(forKey: Self.lockPreferenceKey)])
  }

  /// The flag lives in UserDefaults, not the WebView's website-data store — a cleared or
  /// evicted web store (Safari's "Clear History", low-disk eviction, a reinstalled WKWebView)
  /// can never silently switch a security setting off, because nothing about clearing web
  /// storage touches UserDefaults.
  @objc func setLockPreference(_ call: CAPPluginCall) {
    guard let enabled = call.getBool("enabled") else {
      call.resolve(["status": "invalid"])
      return
    }
    UserDefaults.standard.set(enabled, forKey: Self.lockPreferenceKey)
    call.resolve(["status": "ok", "enabled": enabled])
  }
}
