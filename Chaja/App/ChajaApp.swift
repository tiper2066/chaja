import SwiftUI

@main
struct ChajaApp: App {
    @State private var model = SearchModel()

    var body: some Scene {
        Window("Chaja", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1320, height: 820)
        .windowToolbarStyle(.unified)
        .commands { ChajaCommands(model: model) }
    }
}

struct ChajaCommands: Commands {
    let model: SearchModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("찾기") { model.requestSearchFocus() }
                .keyboardShortcut("f")
            Button("지금 검색") { model.search() }
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
