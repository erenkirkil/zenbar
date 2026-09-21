import AppKit
import Carbon.HIToolbox

/// ZenBar'ı klavyeden aç/kapa etmenin iki yolu.
///
/// **Neden iki yol var:** İstenen kısayol `fn+Z`. Carbon'un `RegisterEventHotKey`
/// modifier kümesinde fn YOKTUR (yalnızca cmd/shift/option/control), dolayısıyla fn'li
/// bir kombinasyon Carbon ile bağlanamaz. Onu yakalamanın tek yolu bir `CGEventTap`'tir
/// — ve tap, sistem genelinde her tuş olayının içinden geçtiği bir bileşendir.
///
/// Bu yüzden varsayılan davranış Carbon'dur (tap yok, ek maliyet sıfır) ve fn+Z
/// kullanıcının menüden açtığı isteğe bağlı bir eklentidir. Kapalıyken tap hiç kurulmaz.
///
/// Not: fn+Z açıkken bile parola alanı odaktayken macOS Secure Event Input tap'e olay
/// göndermez — yani parolalar tap'e hiç ulaşmaz, ama o sırada fn+Z de çalışmaz.
@MainActor
final class ToggleHotkey {

    /// Kısayol tetiklendiğinde çağrılır (her zaman ana thread).
    var onTrigger: (() -> Void)?

    static let fnEnabledKey = "ZenBarFnHotkeyEnabled"

    /// 'Z' tuşunun sanal kodu. Hem Carbon hem tap yolu bunu kullanır.
    private static let keyCodeZ = UInt32(kVK_ANSI_Z)

    /// 'ZNBR' — bu uygulamanın kısayol imzası.
    private static let signature: OSType = 0x5A_4E_42_52

    // MARK: - Paylaşılan örnek (C callback'leri bağlam yakalayamaz)

    nonisolated(unsafe) fileprivate static var shared: ToggleHotkey?

    init() {
        ToggleHotkey.shared = self
    }

    // MARK: - Carbon kısayolu (varsayılan yol)

    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// Varsayılan kısayol: **Ctrl+Opt+Shift+Z**.
    /// Bu bölge Tiler'in ölçümünde boş çıkmıştı (43/43) ve Tiler'in kendi
    /// bağlamalarıyla (ok tuşları + F) çakışmaz.
    func installCarbonHotkey() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard event != nil else { return OSStatus(eventNotHandledErr) }
            guard let owner = ToggleHotkey.shared else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { owner.onTrigger?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: ToggleHotkey.signature, id: 1)
        let modifiers = UInt32(controlKey | optionKey | shiftKey)
        let status = RegisterEventHotKey(ToggleHotkey.keyCodeZ, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            zenbar_logMessage("[ToggleHotkey] Ctrl+Opt+Shift+Z kaydedilemedi (durum \(status))")
        }
    }

    // MARK: - fn+Z (isteğe bağlı, CGEventTap)

    private var tapThread: Thread?

    var isFnHotkeyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: ToggleHotkey.fnEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: ToggleHotkey.fnEnabledKey)
            if newValue { startFnTap() } else { stopFnTap() }
        }
    }

    /// fn+Z tap'i yalnızca Erişilebilirlik izni varken kurulabilir.
    var canEnableFnHotkey: Bool { AXIsProcessTrusted() }

    func startFnTapIfEnabled() {
        if isFnHotkeyEnabled { startFnTap() }
    }

    private func startFnTap() {
        guard tapThread == nil else { return }
        guard canEnableFnHotkey else {
            zenbar_logMessage("[ToggleHotkey] fn+Z istendi ama Erişilebilirlik izni yok")
            return
        }

        let thread = Thread {
            // Tap kendi run loop'unda yaşar; ana UI thread'iyle çekişmez.
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,           // olayı yutabilmek için (listenOnly değil)
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue)
                    | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
                    | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue),
                callback: zenbarFnTapCallback,
                userInfo: nil
            ) else {
                zenbar_logMessage("[ToggleHotkey] CGEventTap oluşturulamadı")
                return
            }

            zenbarFnTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            zenbar_logMessage("[ToggleHotkey] fn+Z tap etkin")

            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.5, false)
            }

            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            zenbarFnTap = nil
            zenbar_logMessage("[ToggleHotkey] fn+Z tap kapatıldı")
        }
        thread.name = "ZenBar.fnhotkey"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    private func stopFnTap() {
        tapThread?.cancel()
        tapThread = nil
    }

    func shutdown() {
        stopFnTap()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }
}

// MARK: - Tap callback'i (tap iş parçacığında çalışır)

/// Tap'in kendisi; yalnızca tap iş parçacığında yazılır, callback'ten okunur.
nonisolated(unsafe) private var zenbarFnTap: CFMachPort?

/// @convention(c) callback — bağlam yakalayamaz, yalnızca globalleri kullanır.
///
/// Maliyeti kritik: bu fonksiyon sistemdeki HER tuş basışında çalışır. Bu yüzden
/// önce en ucuz iki kontrol yapılır (fn bayrağı + tuş kodu) ve eşleşmeyen her olay
/// hemen geri verilir — eşleşmeyen durumda allocation veya AppKit çağrısı yoktur.
private nonisolated func zenbarFnTapCallback(proxy: CGEventTapProxy,
                                             type: CGEventType,
                                             event: CGEvent,
                                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let passthrough = Unmanaged.passUnretained(event)

    // macOS, callback'i çok yavaş bulursa tap'i kapatır; yeniden etkinleştir.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = zenbarFnTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return passthrough
    }

    guard type == .keyDown else { return passthrough }

    // Ucuz eleme: fn basılı değilse hiçbir şey yapma.
    guard event.flags.contains(.maskSecondaryFn) else { return passthrough }

    // fn dışında bir değiştirici varsa bu bizim kısayolumuz değil.
    let others: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    guard event.flags.intersection(others).isEmpty else { return passthrough }

    guard event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_Z) else {
        return passthrough
    }

    DispatchQueue.main.async {
        MainActor.assumeIsolated { ToggleHotkey.shared?.onTrigger?() }
    }
    return nil   // olayı yut — 'z' harfi hiçbir yere yazılmaz
}
