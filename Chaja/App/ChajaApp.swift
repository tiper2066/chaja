import SwiftUI

@main
struct ChajaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = SearchModel()

    var body: some Scene {
        Window("Chaja", id: MainWindow.id) {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands { ChajaCommands(model: model) }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HotKeyService.shared.applySettings()
    }

    /// 창을 닫아도 앱은 남아 있어야 전역 단축키로 다시 불러올 수 있다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if let window = MainWindow.window {
                window.makeKeyAndOrderFront(nil)
            } else {
                MainWindow.open?()
            }
        }
        return true
    }
}

struct ChajaCommands: Commands {
    let model: SearchModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("찾기") { model.requestSearchFocus() }
                .keyboardShortcut("f")
            Button("지금 검색") { model.search(explicit: true) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.criteria.canSearch)
        }

        CommandGroup(after: .newItem) {
            Divider()
            Button("열기") { model.open(model.selectedItems) }
                .keyboardShortcut("o")
                .disabled(model.selection.isEmpty)
            Button("Finder에서 보기") { model.revealInFinder(model.selectedItems) }
                .keyboardShortcut("r")
                .disabled(model.selection.isEmpty)
            Button("훑어보기") { model.toggleQuickLook() }
                .keyboardShortcut("y")
                .disabled(model.selection.isEmpty)
            Button("경로 복사") { model.copyPaths(model.selectedItems) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selection.isEmpty)
            Divider()
            Button("휴지통으로 이동") { moveSelectionToTrash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
        }

        CommandGroup(replacing: .saveItem) {
            Button("검색 저장…") { model.isPresentingSaveSearch = true }
                .keyboardShortcut("s")
                .disabled(!model.criteria.hasConditions)
        }

        CommandMenu("검색") {
            if model.library.saved.isEmpty {
                Text("저장된 검색 없음")
            }
            ForEach(Array(model.library.saved.prefix(9).enumerated()), id: \.element.id) { index, saved in
                Button(saved.name) { model.apply(saved.criteria) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Menu("최근 검색") {
                ForEach(model.library.recent) { recent in
                    Button(recent.criteria.summary) { model.apply(recent.criteria) }
                }
                if !model.library.recent.isEmpty {
                    Divider()
                    Button("최근 검색 지우기") { model.library.clearRecent() }
                }
            }
            .disabled(model.library.recent.isEmpty)
            Divider()
            Button("필터 초기화") { model.resetFilters() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }

    /// 텍스트 입력 중의 ⌘⌫는 원래 동작(줄 앞까지 지우기)을 유지한다.
    private func moveSelectionToTrash() {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return
        }
        let items = model.selectedItems
        Task { await model.moveToTrash(items) }
    }
}
