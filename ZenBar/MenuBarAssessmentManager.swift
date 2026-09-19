import AppKit
import Foundation

/// macOS 27 ve sonrası için MenuBarClientCore.framework üzerinden
/// dinamik Allowlist tabanlı yerel menü çubuğu gizleme yöneticisi.
///
/// Herhangi bir görsel katman veya yapay pencere açmadan,
/// sistem seviyesinde istenen uygulamaları natif olarak gizler.
@MainActor
final class MenuBarAssessmentManager {
    static let shared = MenuBarAssessmentManager()

    private var activeAssertion: AnyObject?
    private var activeConfiguration: AnyObject?

    /// Sistem kontrolleri (Pil, Wi-Fi, Saat, Denetim Merkezi vb.)
    /// macOS 27 MBSystemItemIdentifier canonical enum aralığı:
    /// 0: battery, 1: bluetooth, 2: clock, 3: displays, 4: keyboard, 5: volume, 6: wifi, 7: screenMirroring, 8: primaryBentoBox
    static let allSystemItems: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
    static let defaultAllowedSystemItems: [Int] = [2, 8] // Saat (2) ve Denetim Merkezi (8) daima görünür kalır

    private init() {
        zenbar_logMessage("[MenuBarAssessmentManager] init, isSupported: \(isSupported)")
    }

    isolated deinit {
        showIcons()
    }

    /// Sistemde yerel gizleme desteğinin bulunup bulunmadığı
    var isSupported: Bool {
        return zenbar_assessmentModeAvailable()
    }

    /// Belirtilen Bundle ID'leri ve sistem öğelerini menü çubuğundan natif olarak gizler.
    ///
    /// - Parameters:
    ///   - excludingBundleIDs: Gizlenmesi istenen uygulama paket kimlikleri.
    ///   - allowedSystemItems: Görünür kalmasına izin verilen sistem kontrol kimlikleri (varsayılan: [2, 8] yani Saat ve Denetim Merkezi).
    /// - Returns: İşlem başarılı ise true.
    @discardableResult
    func hideIcons(excludingBundleIDs: Set<String>, allowedSystemItems: [Int] = MenuBarAssessmentManager.defaultAllowedSystemItems) -> Bool {
        guard isSupported else {
            zenbar_logMessage("[MenuBarAssessmentManager] hideIcons called but assessment mode is NOT available")
            return false
        }

        zenbar_logMessage("[MenuBarAssessmentManager] hideIcons called with excluding: \(Array(excludingBundleIDs)), allowedSystemItems: \(allowedSystemItems)")

        if excludingBundleIDs.isEmpty && allowedSystemItems.count >= MenuBarAssessmentManager.allSystemItems.count {
            showIcons()
            return true
        }

        // Sistemdeki tüm çalışan uygulamaları al (yalnızca geçerli paket kimliği olanlar)
        var allowedBundles = Set<String>()
        autoreleasepool {
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier, bid.contains(".") {
                    allowedBundles.insert(bid)
                }
            }
        }

        // Gizlenecek uygulamaları izinli listeden çıkar (ZenBar ve temel sistem servisleri asla çıkarılamaz)
        var sanitizedExcluding = excludingBundleIDs
        let exemptBundles: Set<String> = [
            "com.erenkirkil.ZenBar",
            Bundle.main.bundleIdentifier ?? "com.erenkirkil.ZenBar",
            NSRunningApplication.current.bundleIdentifier ?? "com.erenkirkil.ZenBar",
            "com.apple.MenuBarAgent",
            "com.apple.systemuiserver",
            "com.apple.controlcenter",
            "com.apple.TextInputMenuAgent"
        ]
        sanitizedExcluding.subtract(exemptBundles)
        allowedBundles.subtract(sanitizedExcluding)

        // ZenBar'ın kendisi ve temel sistem agent'larını her zaman izinli listeye ekle
        for b in exemptBundles {
            allowedBundles.insert(b)
        }

        let systemItemsArray = allowedSystemItems.map { NSNumber(value: $0) }
        let bundleIDsArray = Array(allowedBundles)

        zenbar_logMessage("[MenuBarAssessmentManager] Creating config with \(systemItemsArray.count) system items and \(bundleIDsArray.count) allowed bundles")

        guard let config = zenbar_makeConfiguration(systemItemsArray, bundleIDsArray) else {
            zenbar_logMessage("[MenuBarAssessmentManager] Failed to create MBAssessmentModeConfiguration")
            return false
        }

        let prevAssertion = self.activeAssertion

        guard let handle = zenbar_activateAssertion(config, { @Sendable error in
            Task { @MainActor in
                if let error = error {
                    zenbar_logMessage("[MenuBarAssessmentManager] Assertion callback error: \(error.localizedDescription)")
                } else {
                    zenbar_logMessage("[MenuBarAssessmentManager] Assertion callback OK — successfully active in MenuBarAgent")
                }
            }
        }) else {
            zenbar_logMessage("[MenuBarAssessmentManager] Failed to activate MBAssessmentModeAssertion")
            return false
        }

        self.activeAssertion = handle as AnyObject
        self.activeConfiguration = config as AnyObject

        if let prev = prevAssertion {
            zenbar_logMessage("[MenuBarAssessmentManager] Invalidating previous assertion...")
            zenbar_invalidateAssertion(prev)
        }

        zenbar_logMessage("[MenuBarAssessmentManager] hideIcons completed successfully, assertion active")
        return true
    }

    /// Gizlenen simgeleri anında eski haline getirir.
    func showIcons() {
        zenbar_logMessage("[MenuBarAssessmentManager] showIcons called, activeAssertion is \(activeAssertion != nil ? "NON-NIL" : "NIL")")
        guard let assertion = activeAssertion else {
            zenbar_invalidateAssertion(nil)
            return
        }
        zenbar_invalidateAssertion(assertion)
        self.activeAssertion = nil
        self.activeConfiguration = nil
    }
}
