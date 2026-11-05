import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Carbon 전역 단축키. 손쉬운 사용 권한 없이 다른 앱을 쓰는 중에도 동작한다.
final class HotKeyService {
    static let shared = HotKeyService()

    var onPress: (() -> Void)?
    private(set) var registrationFailed = false

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 설정값대로 다시 등록한다. 다른 앱이 이미 쓰는 조합이면 실패하고 `registrationFailed`가 켜진다.
    @discardableResult
    func applySettings() -> Bool {
        unregister()
        guard AppSettings.hotKeyEnabled else {
            registrationFailed = false
            return true
        }
        installHandlerIfNeeded()
        let hotKey = AppSettings.hotKey
        let id = EventHotKeyID(signature: OSType(0x4348_4A41), id: 1) // 'CHJA'
        let status = RegisterEventHotKey(UInt32(hotKey.keyCode), hotKey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        registrationFailed = status != noErr
        return !registrationFailed
    }

    func suspend() {
        unregister()
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKeyService.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

/// 메인 창이 닫혀 있어도 단축키로 다시 열 수 있게 SwiftUI의 창 열기 동작을 보관한다.
enum MainWindow {
    static let id = "main"
    static var open: (() -> Void)?

    static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true && $0.canBecomeMain }
    }

    /// 앞에 떠 있으면 숨기고(Spotlight처럼), 아니면 불러온다.
    static func toggle(focusSearch: () -> Void) {
        if NSApp.isActive, let window, window.isVisible, window.isKeyWindow {
            NSApp.hide(nil)
            return
        }
        NSApp.unhide(nil)
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
        focusSearch()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
