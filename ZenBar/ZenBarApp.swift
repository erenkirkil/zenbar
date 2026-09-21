import AppKit
import ApplicationServices
import ServiceManagement

enum MBSystemItem: Int, CaseIterable {
    case battery = 0
    case bluetooth = 1
    case clock = 2
    case displays = 3
    case keyboard = 4
    case volume = 5
    case wifi = 6
    case screenMirroring = 7
    case primaryBentoBox = 8

    var displayName: String {
        switch self {
        case .battery: return "Pil (Battery)"
        case .bluetooth: return "Bluetooth"
        case .clock: return "Saat (Clock)"
        case .displays: return "Ekran (Displays)"
        case .keyboard: return "Klavye (Keyboard)"
        case .volume: return "Ses (Volume)"
        case .wifi: return "Wi-Fi"
        case .screenMirroring: return "Ekran Yansıtma (Screen Mirroring)"
        case .primaryBentoBox: return "Denetim Merkezi (Control Center)"
        }
    }

    static var allItemIDs: [Int] {
        return allCases.map(\.rawValue)
    }

    /// Menüde kullanıcının gizlemeyi seçebileceği kontroller (Saat ve Denetim Merkezi dahil!)
    static var hideableCases: [MBSystemItem] {
        return [.battery, .bluetooth, .displays, .screenMirroring, .volume, .wifi, .keyboard, .clock, .primaryBentoBox]
    }

    /// Varsayılan olarak gizlenecek kontroller (Saat (2) ve Denetim Merkezi (8) hariç)
    static var defaultHiddenCases: [MBSystemItem] {
        return [.battery, .bluetooth, .displays, .screenMirroring, .volume, .wifi, .keyboard]
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemToggle: NSStatusItem!
    var statusItemSeparator: NSStatusItem?

    static let leafImage: NSImage? = {
        let img = NSImage(systemSymbolName: "leaf", accessibilityDescription: "ZenBarToggle")
        img?.isTemplate = true
        return img
    }()

    static let leafFillImage: NSImage? = {
        let img = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "ZenBarToggle")
        img?.isTemplate = true
        return img
    }()

    static let separatorImage: NSImage? = {
        let img = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "ZenBarSeparator")
        img?.isTemplate = true
        return img
    }()

    static let toggleEditImage: NSImage? = {
        let img = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "ZenBarToggle")
        img?.isTemplate = true
        return img
    }()
    
    var isExpanded: Bool = true 
    var isEditMode: Bool = false
    var autoCollapseTimer: Timer?
    var lastSeparatorX: CGFloat?
    private var lastToggleTimestamp: TimeInterval = 0

    let assessmentManager = MenuBarAssessmentManager.shared
    let hotkey = ToggleHotkey()

    private let hiddenBundlesKey = "ZenBarHiddenBundleIDs"
    private var cachedHiddenBundleIDs: Set<String> = []

    /// Önbelleğin yüklenip yüklenmediğini ayrı tutarız: "boş küme" artık geçerli bir
    /// durumdur (varsayılan boş liste). Eskiden boşluk "önbellek dolu değil" sayıldığı
    /// için her erişimde UserDefaults'a gidiliyordu.
    private var hiddenBundlesLoaded = false

    var hiddenBundleIDs: Set<String> {
        get {
            if !hiddenBundlesLoaded {
                cachedHiddenBundleIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenBundlesKey) ?? [])
                hiddenBundlesLoaded = true
            }
            return cachedHiddenBundleIDs
        }
        set {
            cachedHiddenBundleIDs = newValue
            hiddenBundlesLoaded = true
            UserDefaults.standard.set(Array(newValue), forKey: hiddenBundlesKey)
        }
    }

    private let hideSystemIconsKey = "ZenBarHideSystemIcons"
    private let hiddenSystemItemsKey = "ZenBarHiddenSystemItems_v2"

    var hideSystemIcons: Bool {
        get {
            if UserDefaults.standard.object(forKey: hideSystemIconsKey) == nil {
                return true // Varsayılan: Sistem ikonlarını da gizle
            }
            return UserDefaults.standard.bool(forKey: hideSystemIconsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: hideSystemIconsKey)
            UserDefaults.standard.synchronize()
        }
    }

    var hiddenSystemItems: Set<Int> {
        get {
            if let saved = UserDefaults.standard.array(forKey: hiddenSystemItemsKey) as? [Int] {
                return Set(saved)
            }
            return Set(MBSystemItem.defaultHiddenCases.map(\.rawValue))
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: hiddenSystemItemsKey)
            UserDefaults.standard.synchronize()
        }
    }

    var currentAllowedSystemItems: [Int] {
        if !hideSystemIcons {
            return MBSystemItem.allItemIDs
        }
        let hidden = hiddenSystemItems
        return MBSystemItem.allItemIDs.filter { !hidden.contains($0) }
    }

    static var shared: AppDelegate!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.finishLaunching()
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Sürüm bundle'dan okunur; koda sabitlenirse her yayında elle güncellemek gerekir
        // ve kaçınılmaz olarak kayar.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        zenbar_logMessage("[ZenBarApp] Launching v\(version)")

        // Varsayılan gizli uygulama listesi BOŞ gelir. Daha önce burada geliştiricinin
        // kendi uygulamaları (tiler, closetoquit, docktoggle, sclip, antigravity) sabit
        // olarak yazılıydı ve sclip her açılışta kullanıcı ayarına zorla geri ekleniyordu
        // — yani kullanıcının menüden kaldırdığı seçim her başlangıçta geri geliyordu.
        // Hangi uygulamanın gizleneceği yalnızca kullanıcının kararıdır.
        UserDefaults.standard.register(defaults: [
            hiddenBundlesKey: [String](),
            hideSystemIconsKey: true,
            hiddenSystemItemsKey: MBSystemItem.defaultHiddenCases.map(\.rawValue)
        ])
        cachedHiddenBundleIDs = Set(UserDefaults.standard.stringArray(forKey: hiddenBundlesKey) ?? [])
        hiddenBundlesLoaded = true

        let checkOpt = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(checkOpt)
        zenbar_logMessage("[ZenBarApp] Accessibility trusted: \(isTrusted)")

        // Clear any stale invisible autosave state from UserDefaults
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible ZenBarToggle")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC ZenBarToggle")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem Visible ZenBarSeparator")
        UserDefaults.standard.removeObject(forKey: "NSStatusItem VisibleCC ZenBarSeparator")

        statusItemToggle = NSStatusBar.system.statusItem(withLength: 28)
        statusItemToggle.isVisible = true
        statusItemToggle.behavior = .removalAllowed
        statusItemToggle.autosaveName = "ZenBarToggle"
        if let button = statusItemToggle.button {
            button.action = #selector(toggleIcons)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("ZenBarToggle")
            button.setAccessibilityTitle("ZenBarToggle")
        }

        // Klavye kısayolu: Ctrl+Opt+Shift+Z her zaman kayıtlıdır (Carbon, tap yok).
        // fn+Z yalnızca kullanıcı menüden açtıysa kurulur.
        hotkey.onTrigger = { [weak self] in
            self?.performToggle()
        }
        hotkey.installCarbonHotkey()
        hotkey.startFnTapIfEnabled()

        updateIcons()
        relieveMemoryPressure()
    }

    @objc func toggleFnHotkey() {
        if !hotkey.isFnHotkeyEnabled && !hotkey.canEnableFnHotkey {
            // Tap Erişilebilirlik izni olmadan kurulamaz; kullanıcıyı panele yönlendir.
            let alert = NSAlert()
            alert.messageText = "fn+Z için Erişilebilirlik izni gerekiyor"
            alert.informativeText = """
                fn tuşlu kısayollar yalnızca bir olay dinleyicisiyle yakalanabilir ve bu \
                dinleyici Erişilebilirlik izni ister. İzni verdikten sonra bu seçeneği \
                tekrar işaretleyebilirsin.

                Ctrl+Opt+Shift+Z kısayolu izin olmadan da çalışır.
                """
            alert.addButton(withTitle: "Ayarları Aç")
            alert.addButton(withTitle: "Vazgeç")
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }
        hotkey.isFnHotkeyEnabled.toggle()
    }

    private var memoryReliefWorkItem: DispatchWorkItem?

    /// `malloc_zone_pressure_relief` malloc bölgesini gezip boş sayfaları çekirdeğe
    /// geri verir — ucuz değildir. Geçişin ortasında ana thread'de çağrılırsa ikonlar
    /// yeniden dizilirken araya girer. Bu yüzden geçiş oturduktan sonraya ertelenir ve
    /// arka arkaya tıklamalarda tek çağrıya indirgenir (coalesce).
    private func relieveMemoryPressure() {
        memoryReliefWorkItem?.cancel()
        let item = DispatchWorkItem {
            malloc_zone_pressure_relief(malloc_default_zone(), 0)
        }
        memoryReliefWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
    
    // 10 Saniye sonra otomatik gizleyen sayaç (yalnızca kullanıcı menüyü açtığında devreye girer)
    func resetAutoCollapseTimer() {
        autoCollapseTimer?.invalidate()
        if isExpanded && !isEditMode {
            autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    if self.isExpanded {
                        self.isExpanded = false
                        self.updateIcons()
                    }
                }
            }
        }
    }

    // Mac açılışında otomatik başlama ayarı
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Launch at login hatası: \(error)")
        }
    }

    @objc func toggleEditMode() {
        isEditMode.toggle()
        if isEditMode { 
            isExpanded = true 
            autoCollapseTimer?.invalidate()
        } else {
            // Edit modu kapatıldığında ayırıcının yeni konumuna göre solundaki uygulamaları algıla
            let newLeft = detectLeftHandBundleIDs()
            if !newLeft.isEmpty {
                hiddenBundleIDs = newLeft
            }
            resetAutoCollapseTimer()
        }
        updateIcons()
    }

    func detectThirdPartyApps() -> [NSRunningApplication] {
        autoreleasepool {
            return NSWorkspace.shared.runningApplications.filter { app in
                guard let bundleID = app.bundleIdentifier else { return false }
                if bundleID.hasPrefix("com.apple.") { return false }
                if bundleID == Bundle.main.bundleIdentifier || bundleID == "com.erenkirkil.ZenBar" { return false }
                return app.activationPolicy == .accessory || app.activationPolicy == .regular || app.activationPolicy == .prohibited
            }
        }
    }

    /// macOS 27 AX yapısında MenuBarAgent altındaki gerçek uygulama PID'sini bulur
    private func findOwnerPID(in element: AXUIElement, agentPID: pid_t) -> pid_t? {
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success && pid != 0 && pid != agentPID {
            return pid
        }
        var childrenVal: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenVal) == .success,
           let children = childrenVal as? [AXUIElement] {
            for child in children {
                if let found = findOwnerPID(in: child, agentPID: agentPID) {
                    return found
                }
            }
        }
        return nil
    }

    private func systemItemFrom(description: String) -> MBSystemItem? {
        let lower = description.lowercased()
        if lower.contains("battery") || lower.contains("pil") || lower.contains("power") {
            return .battery
        }
        if lower.contains("bluetooth") {
            return .bluetooth
        }
        if lower.contains("clock") || lower.contains("saat") || lower.contains("time") {
            return .clock
        }
        if (lower.contains("display") || lower.contains("ekran")) && !lower.contains("yansıtma") && !lower.contains("mirroring") {
            return .displays
        }
        if lower.contains("keyboard") || lower.contains("klavye") || lower.contains("input source") {
            return .keyboard
        }
        if lower.contains("sound") || lower.contains("volume") || lower.contains("ses") {
            return .volume
        }
        if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("airport") {
            return .wifi
        }
        if lower.contains("mirroring") || lower.contains("yansıtma") || lower.contains("airplay") || lower.contains("screen mirroring") {
            return .screenMirroring
        }
        if lower.contains("bento") || lower.contains("control center") || lower.contains("denetim merkezi") {
            return .primaryBentoBox
        }
        return nil
    }

    func detectLeftHandBundleIDs() -> Set<String> {
        autoreleasepool {
            guard AXIsProcessTrusted() else {
                zenbar_logMessage("[ZenBarApp] Accessibility not trusted yet, returning existing hiddenBundleIDs")
                return hiddenBundleIDs
            }
            guard let agent = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.MenuBarAgent" }) else {
                zenbar_logMessage("[ZenBarApp] MenuBarAgent not found")
                return hiddenBundleIDs
            }
            let axApp = AXUIElementCreateApplication(agent.processIdentifier)
            var windowsVal: AnyObject?
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal)
            guard let windows = windowsVal as? [AXUIElement], let win = windows.first else {
                return hiddenBundleIDs
            }
            var childrenVal: AnyObject?
            AXUIElementCopyAttributeValue(win, kAXChildrenAttribute as CFString, &childrenVal)
            guard let groups = childrenVal as? [AXUIElement] else {
                return hiddenBundleIDs
            }

            var detectedSepX: CGFloat?
            if let sepWindow = statusItemSeparator?.button?.window {
                let frameX = sepWindow.frame.origin.x
                if frameX > 0 {
                    detectedSepX = frameX
                }
            }

            let myPID = ProcessInfo.processInfo.processIdentifier
            var zenBarPositions: [CGFloat] = []
            var otherApps: [(bundleID: String, x: CGFloat)] = []
            var detectedSystemItems: [(item: MBSystemItem, x: CGFloat)] = []

            for g in groups {
                var posVal: AnyObject?
                if AXUIElementCopyAttributeValue(g, kAXPositionAttribute as CFString, &posVal) != .success || posVal == nil {
                    continue
                }
                guard let posVal = posVal else { continue }
                var pt = CGPoint.zero
                guard AXValueGetValue(posVal as! AXValue, .cgPoint, &pt) else { continue }

                let ownerPID = findOwnerPID(in: g, agentPID: agent.processIdentifier) ?? 0

                if ownerPID == myPID {
                    zenBarPositions.append(pt.x)
                    var descVal: AnyObject?
                    AXUIElementCopyAttributeValue(g, kAXDescriptionAttribute as CFString, &descVal)
                    var titleVal: AnyObject?
                    AXUIElementCopyAttributeValue(g, kAXTitleAttribute as CFString, &titleVal)
                    let desc = (descVal as? String) ?? (titleVal as? String) ?? ""
                    if desc.contains("Separator") || desc.contains("Ayırıcı") {
                        detectedSepX = pt.x
                    }
                } else if ownerPID != 0,
                          let app = NSRunningApplication(processIdentifier: ownerPID),
                          let bundleID = app.bundleIdentifier,
                          !bundleID.hasPrefix("com.apple.") {
                    otherApps.append((bundleID: bundleID, x: pt.x))
                } else {
                    var descVal: AnyObject?
                    AXUIElementCopyAttributeValue(g, kAXDescriptionAttribute as CFString, &descVal)
                    var titleVal: AnyObject?
                    AXUIElementCopyAttributeValue(g, kAXTitleAttribute as CFString, &titleVal)
                    let desc = (descVal as? String) ?? (titleVal as? String) ?? ""
                    if let sysItem = systemItemFrom(description: desc) {
                        detectedSystemItems.append((item: sysItem, x: pt.x))
                    }
                }
            }

            let toggleX: CGFloat = {
                if let w = statusItemToggle.button?.window?.frame.origin.x, w > 0 { return w }
                if !zenBarPositions.isEmpty { return zenBarPositions.max()! }
                return 999999
            }()

            let minAppX = otherApps.map(\.x).min() ?? 0
            let sepX: CGFloat
            if let found = detectedSepX, found > minAppX, found < toggleX {
                sepX = found
                lastSeparatorX = found
            } else {
                sepX = toggleX
                lastSeparatorX = toggleX
            }

            var leftBundles: Set<String> = []
            for app in otherApps {
                if app.x < sepX {
                    leftBundles.insert(app.bundleID)
                }
            }

            if !detectedSystemItems.isEmpty {
                var newHiddenSys: Set<Int> = []
                for sys in detectedSystemItems {
                    // Saat (clock) ve Denetim Merkezi (primaryBentoBox) varsayılan olarak korunur
                    if sys.x < sepX && sys.item != .clock && sys.item != .primaryBentoBox {
                        newHiddenSys.insert(sys.item.rawValue)
                    }
                }
                if !newHiddenSys.isEmpty {
                    // Kullanıcının sağ tık menüsünden özel olarak seçtiği Saat veya Denetim Merkezi tercihlerini koru
                    let explicitUserSelections = hiddenSystemItems.intersection([MBSystemItem.clock.rawValue, MBSystemItem.primaryBentoBox.rawValue])
                    hiddenSystemItems = newHiddenSys.union(explicitUserSelections)
                }
                zenbar_logMessage("[ZenBarApp] detectLeftHandBundleIDs detected \(detectedSystemItems.count) sys items, hidden: \(Array(hiddenSystemItems))")
            }

            zenbar_logMessage("[ZenBarApp] detectLeftHandBundleIDs found \(leftBundles.count) left-hand bundles (sepX=\(sepX), toggleX=\(toggleX)): \(Array(leftBundles))")
            return leftBundles.isEmpty ? hiddenBundleIDs : leftBundles
        }
    }

    @objc func toggleAppHiding(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var current = hiddenBundleIDs
        if current.contains(bundleID) {
            current.remove(bundleID)
        } else {
            current.insert(bundleID)
        }
        hiddenBundleIDs = current
        if !isExpanded {
            updateIcons()
        }
    }

    @objc func toggleHideSystemIcons() {
        hideSystemIcons.toggle()
        if !isExpanded {
            updateIcons()
        }
    }

    @objc func toggleSystemItemHiding(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? Int else { return }
        var current = hiddenSystemItems
        if current.contains(rawID) {
            current.remove(rawID)
        } else {
            current.insert(rawID)
        }
        hiddenSystemItems = current
        if !isExpanded {
            updateIcons()
        }
    }

    @objc func toggleIcons() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()

            // Gizleme, macOS'un özel MenuBarClientCore framework'üne dayanır. Apple bunu
            // bir ara sürümde yeniden adlandırır/kaldırırsa uygulama sessizce işlevsiz
            // kalırdı; bu durumu kullanıcıya açıkça söyle.
            if !assessmentManager.isSupported {
                let warning = NSMenuItem(
                    title: "⚠️ Gizleme bu macOS sürümünde çalışmıyor",
                    action: nil, keyEquivalent: "")
                warning.isEnabled = false
                menu.addItem(warning)
                let detail = NSMenuItem(
                    title: "Sistem menü çubuğu arayüzü değişmiş olabilir.",
                    action: nil, keyEquivalent: "")
                detail.isEnabled = false
                menu.addItem(detail)
                menu.addItem(NSMenuItem.separator())
            }

            let editTitle = isEditMode ? "Düzenlemeyi Bitir" : "İkonların Yerini Düzenle"
            menu.addItem(NSMenuItem(title: editTitle, action: #selector(toggleEditMode), keyEquivalent: "e"))
            
            // Gizlenecek uygulamalar alt menüsü
            let appsMenu = NSMenu()
            let thirdPartyApps = detectThirdPartyApps()
            let currentHidden = hiddenBundleIDs

            if thirdPartyApps.isEmpty {
                let emptyItem = NSMenuItem(title: "Çalışan Üçüncü Taraf Uygulama Yok", action: nil, keyEquivalent: "")
                emptyItem.isEnabled = false
                appsMenu.addItem(emptyItem)
            } else {
                for app in thirdPartyApps {
                    guard let bundleID = app.bundleIdentifier else { continue }
                    let name = app.localizedName ?? bundleID
                    let item = NSMenuItem(title: name, action: #selector(toggleAppHiding(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = bundleID
                    item.state = currentHidden.contains(bundleID) ? .on : .off
                    appsMenu.addItem(item)
                }
            }

            let appsParentItem = NSMenuItem(title: "Gizlenecek Uygulamalar", action: nil, keyEquivalent: "")
            appsParentItem.submenu = appsMenu
            menu.addItem(appsParentItem)

            // Sistem ikonları alt menüsü
            let sysMenu = NSMenu()
            let masterSysItem = NSMenuItem(title: "Sistem İkonlarını Gizle", action: #selector(toggleHideSystemIcons), keyEquivalent: "")
            masterSysItem.target = self
            masterSysItem.state = hideSystemIcons ? .on : .off
            sysMenu.addItem(masterSysItem)
            sysMenu.addItem(NSMenuItem.separator())

            let currentHiddenSys = hiddenSystemItems
            for item in MBSystemItem.hideableCases {
                let sysItem = NSMenuItem(title: item.displayName, action: #selector(toggleSystemItemHiding(_:)), keyEquivalent: "")
                sysItem.target = self
                sysItem.representedObject = item.rawValue
                sysItem.state = currentHiddenSys.contains(item.rawValue) ? .on : .off
                sysMenu.addItem(sysItem)
            }

            let sysParentItem = NSMenuItem(title: "Sistem İkonları", action: nil, keyEquivalent: "")
            sysParentItem.submenu = sysMenu
            menu.addItem(sysParentItem)

            menu.addItem(NSMenuItem.separator())

            // Klavye kısayolu bölümü
            let shortcutInfo = NSMenuItem(title: "Kısayol: ⌃⌥⇧Z", action: nil, keyEquivalent: "")
            shortcutInfo.isEnabled = false
            menu.addItem(shortcutInfo)

            let fnItem = NSMenuItem(title: "fn+Z ile de aç/kapa",
                                    action: #selector(toggleFnHotkey), keyEquivalent: "")
            fnItem.target = self
            fnItem.state = hotkey.isFnHotkeyEnabled ? .on : .off
            // fn'li kısayol Carbon ile bağlanamaz; yalnızca bir klavye olay dinleyicisiyle
            // yakalanabilir. Bu yüzden isteğe bağlıdır ve kapalıyken hiç kurulmaz.
            fnItem.toolTip = "fn'li kısayollar bir klavye olay dinleyicisi gerektirir "
                + "(Erişilebilirlik izni). Kapalıyken dinleyici hiç kurulmaz."
            menu.addItem(fnItem)

            menu.addItem(NSMenuItem.separator())

            // Başlangıçta açılma durumunu kontrol et ve menüye yaz
            let isAutoLaunch = SMAppService.mainApp.status == .enabled
            let launchTitle = isAutoLaunch ? "✓ Başlangıçta Otomatik Açıl" : "Başlangıçta Otomatik Açıl"
            menu.addItem(NSMenuItem(title: launchTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "l"))
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ZenBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            
            statusItemToggle.menu = menu
            statusItemToggle.button?.performClick(nil)
            statusItemToggle.menu = nil
            return
        }

        performToggle()
    }

    /// Asıl aç/kapa. Menü çubuğu düğmesi ve klavye kısayolu aynı yolu kullanır —
    /// debounce dahil, böylece hızlı tekrarlar iki kaynakta da aynı şekilde elenir.
    func performToggle() {
        // Debouncing: 350ms içindeki mükerrer tetiklemeleri yoksay
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleTimestamp < 0.35 {
            zenbar_logMessage("[ZenBarApp] performToggle: debounced rapid trigger (delta: \(now - lastToggleTimestamp)s)")
            return
        }
        lastToggleTimestamp = now

        if isEditMode {
            isEditMode = false
            let newLeft = detectLeftHandBundleIDs()
            if !newLeft.isEmpty {
                hiddenBundleIDs = newLeft
            }
            updateIcons()
            return
        }

        isExpanded.toggle()
        zenbar_logMessage("[ZenBarApp] toggleIcons: toggled isExpanded to \(isExpanded)")
        updateIcons()
        if isExpanded {
            resetAutoCollapseTimer()
        } else {
            autoCollapseTimer?.invalidate()
        }
    }

    func updateIcons() {
        zenbar_logMessage("[ZenBarApp] updateIcons: isEditMode=\(isEditMode), isExpanded=\(isExpanded)")
        if isEditMode {
            assessmentManager.showIcons()
            if statusItemSeparator == nil {
                let sep = NSStatusBar.system.statusItem(withLength: 20)
                sep.autosaveName = "ZenBarSeparator"
                sep.behavior = .removalAllowed
                sep.button?.setAccessibilityLabel("ZenBarSeparator")
                sep.button?.setAccessibilityTitle("ZenBarSeparator")
                statusItemSeparator = sep
            }
            statusItemSeparator?.isVisible = true
            statusItemSeparator?.length = 20
            statusItemSeparator?.button?.image = AppDelegate.separatorImage
            statusItemToggle.button?.image = AppDelegate.toggleEditImage
        } else {
            // Normal kullanımda (açık veya kapalı) ayırıcı tamamen kaldırılır — WindowServer pencere belleğini ve çizgi kalıntılarını sıfırlar
            if let sep = statusItemSeparator {
                NSStatusBar.system.removeStatusItem(sep)
                statusItemSeparator = nil
            }

            statusItemToggle.isVisible = true
            statusItemToggle.length = 28
            statusItemToggle.behavior = .removalAllowed

            if isExpanded {
                // Burada AX taraması YAPILMAZ. showIcons() MenuBarAgent'a tüm öğeleri
                // yeniden dizdirir; o sırada aynı sürece senkron AX sorgusu göndermek
                // ana thread'i kilitler ve ikonlar belirirken görünür kasmaya yol açar.
                // (Daraltmada tarama görsel değişimden önce bittiği için fark edilmiyordu.)
                assessmentManager.showIcons()
                statusItemToggle.button?.image = AppDelegate.leafImage
            } else {
                // Gizlenecek küme yalnızca kullanıcının kararlarından gelir: düzenleme
                // modundan çıkışta yapılan konum tespiti + menüdeki onay kutuları.
                // Eskiden burada da tarama yapılıp sonuç union'lanıyordu; bu, kullanıcı
                // menüden bir uygulamanın işaretini kaldırdığında onu bir sonraki
                // tıklamada geri ekliyordu ve liste yalnızca büyüyordu.
                let toHide = hiddenBundleIDs
                zenbar_logMessage("[ZenBarApp] updateIcons toHide: \(Array(toHide))")
                statusItemToggle.button?.image = AppDelegate.leafFillImage
                if assessmentManager.isSupported {
                    let allowedSys = currentAllowedSystemItems
                    let shouldHide = !toHide.isEmpty || (hideSystemIcons && !hiddenSystemItems.isEmpty)
                    if shouldHide {
                        assessmentManager.hideIcons(excludingBundleIDs: toHide, allowedSystemItems: allowedSys)
                    } else {
                        assessmentManager.showIcons()
                    }
                }
            }
            relieveMemoryPressure()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // showIcons() artık sökümü ~0,45 sn erteliyor (yumuşak geçiş için). Süreç ölürken
        // o zamanlayıcı çalışamaz, bu yüzden koşulsuz ve anında geri alma kullanılır.
        memoryReliefWorkItem?.cancel()
        hotkey.shutdown()
        assessmentManager.restoreImmediately()
    }
}
