import AppKit
import ServiceManagement

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItemToggle: NSStatusItem!
    var statusItemSeparator: NSStatusItem!
    
    var isExpanded: Bool = true 
    var isEditMode: Bool = false
    var autoCollapseTimer: Timer?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItemToggle = NSStatusBar.system.statusItem(withLength: 28)
        statusItemToggle.autosaveName = "ZenBarToggle"
        if let button = statusItemToggle.button {
            button.action = #selector(toggleIcons)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusItemSeparator = NSStatusBar.system.statusItem(withLength: 1)
        statusItemSeparator.autosaveName = "ZenBarSeparator"
        if let button = statusItemSeparator.button {
            button.appearsDisabled = true
        }

        updateIcons()
        resetAutoCollapseTimer()
    }
    
    // 10 Saniye sonra otomatik gizleyen sayaç
    func resetAutoCollapseTimer() {
        autoCollapseTimer?.invalidate()
        if isExpanded && !isEditMode {
            autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if self.isExpanded {
                    self.isExpanded = false
                    self.updateIcons()
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
            resetAutoCollapseTimer()
        }
        updateIcons()
    }

    @objc func toggleIcons() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            
            let editTitle = isEditMode ? "Düzenlemeyi Bitir" : "İkonların Yerini Düzenle"
            menu.addItem(NSMenuItem(title: editTitle, action: #selector(toggleEditMode), keyEquivalent: "e"))
            
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

        if isEditMode {
            isEditMode = false
            updateIcons()
            return
        }

        isExpanded.toggle()
        updateIcons()
        resetAutoCollapseTimer()
    }

    func updateIcons() {
        if isEditMode {
            statusItemSeparator.length = 20
            statusItemSeparator.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Ayırıcı")
            statusItemToggle.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Düzenleniyor")
        } else {
            statusItemSeparator.length = isExpanded ? 1 : 10000
            statusItemSeparator.button?.image = nil
            
            // İKON SEÇİMİ: yin.yang sistemde (SF Symbols) olmadığı için ikon görünmez oluyordu.
            // Bunun yerine yine Zen temasına çok uygun olan 'leaf' (yaprak) ikonunu kullanıyoruz.
            let iconName = isExpanded ? "leaf" : "leaf.fill" 
            statusItemToggle.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "ZenBar")
        }
    }
}
