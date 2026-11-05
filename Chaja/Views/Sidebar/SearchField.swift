import AppKit
import SwiftUI

/// 한글 등 입력기 조합(marked text) 중에는 바인딩을 갱신하지도, 필드 값을 덮어쓰지도 않는 검색 필드.
/// SwiftUI `.searchable`은 조합 중 화면이 다시 그려지면 값을 되써서 "견적"이 "견ㄱ"처럼 깨진다.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String
    var focusRequest = 0
    var isLarge = true
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.controlSize = isLarge ? .large : .small
        field.font = .systemFont(ofSize: isLarge ? 13 : 11)
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if !Self.isComposing(field), field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func isComposing(_ field: NSSearchField) -> Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var lastFocusRequest: Int

        init(parent: SearchField) {
            self.parent = parent
            self.lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, !SearchField.isComposing(field) else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        @objc func submit(_ sender: NSSearchField) {
            if parent.text != sender.stringValue {
                parent.text = sender.stringValue
            }
            parent.onSubmit()
        }
    }
}
