import AppKit
import SwiftUI

/// 결과 리스트. SwiftUI `Table`은 결과가 0.1초마다 비워지고 다시 채워지는 수천 행에서 행 비교가 밀려
/// 몇 초씩 멈추고, 바뀐 배열을 예전 개수로 읽다가 범위 초과로 종료됐다(M5 맥, 전체 Mac에서 "gu").
/// 그래서 `NSTableView`에 결과 사본을 넘기고, 결과 버전이 바뀔 때만 다시 읽게 한다.
struct ResultsTable: View {
    let model: SearchModel
    @Binding var quickLookURL: URL?

    var body: some View {
        ResultsTableView(model: model, version: model.resultsVersion, selection: model.selection,
                         sortField: model.sortField, sortAscending: model.sortAscending,
                         quickLookURL: $quickLookURL)
    }
}

private struct ResultsTableView: NSViewRepresentable {
    let model: SearchModel
    // 아래 값들은 body에서 읽어 넘겨야 바뀔 때 다시 그려진다.
    let version: Int
    let selection: Set<FileItem.ID>
    let sortField: SearchModel.SortField
    let sortAscending: Bool
    @Binding var quickLookURL: URL?

    enum Column: String, CaseIterable {
        case name, location, size, modified, kind

        var title: String {
            switch self {
            case .name: "이름"
            case .location: "위치"
            case .size: "크기"
            case .modified: "수정일"
            case .kind: "종류"
            }
        }

        var sortField: SearchModel.SortField {
            switch self {
            case .name: .name
            case .location: .location
            case .size: .size
            case .modified: .modified
            case .kind: .kind
            }
        }

        /// (최소, 처음, 최대) 폭
        var widths: (CGFloat, CGFloat, CGFloat) {
            switch self {
            case .name: (180, 320, 2000)
            case .location: (120, 260, 2000)
            case .size: (60, 80, 110)
            case .modified: (110, 150, 200)
            case .kind: (80, 130, 220)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = ResultsNSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 6, height: 0)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            tableColumn.title = column.title
            (tableColumn.minWidth, tableColumn.width, tableColumn.maxWidth) = column.widths
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: column.sortField.rawValue, ascending: true)
            if column == .size { tableColumn.headerCell.alignment = .right }
            table.addTableColumn(tableColumn)
        }
        table.autosaveName = "ResultsTable"
        table.autosaveTableColumns = true

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClicked(_:))
        table.onSpace = { [weak coordinator] in coordinator?.parent.model.toggleQuickLook() }
        table.onReturn = { [weak coordinator] in coordinator?.openSelection() }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let menu = NSMenu()
        menu.delegate = coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: ResultsTableView
        weak var table: ResultsNSTableView?
        /// 표가 읽는 결과 사본. 모델 배열이 바뀌는 도중에도 표는 항상 이 사본과 개수가 맞는다.
        private var items: [FileItem] = []
        private var loadedVersion = -1
        private var isApplying = false

        init(parent: ResultsTableView) {
            self.parent = parent
        }

        // MARK: - 모델 → 표

        func apply() {
            guard let table else { return }
            isApplying = true
            defer { isApplying = false }

            if loadedVersion != parent.version {
                loadedVersion = parent.version
                items = parent.model.results
                table.reloadData()
            }

            let descriptor = NSSortDescriptor(key: parent.sortField.rawValue, ascending: parent.sortAscending)
            if table.sortDescriptors.first.map({ $0.key == descriptor.key && $0.ascending == descriptor.ascending }) != true {
                table.sortDescriptors = [descriptor]
            }

            let selection = parent.selection
            let rows = selection.isEmpty ? IndexSet() : IndexSet(items.indices.filter { selection.contains(items[$0].id) })
            if rows != table.selectedRowIndexes {
                table.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        // MARK: - 데이터

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
                  items.indices.contains(row) else { return nil }
            let item = items[row]
            let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: nil) as? ResultCell
                ?? ResultCell(column: column)
            cell.configure(item)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            items.indices.contains(row) ? items[row].url as NSURL : nil
        }

        // MARK: - 표 → 모델

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplying, let table else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil })
            if selected != parent.model.selection {
                parent.model.selection = selected
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplying, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let field = SearchModel.SortField(rawValue: key) else { return }
            parent.model.sortOrder = [SearchModel.comparator(for: field, order: descriptor.ascending ? .forward : .reverse)]
        }

        // MARK: - 동작

        /// 우클릭·두 번 클릭한 행이 선택에 들어 있으면 선택 전체, 아니면 그 행만.
        private func targets(clickedRow row: Int) -> [FileItem] {
            guard let table, items.indices.contains(row) else { return selectedItems }
            return table.selectedRowIndexes.contains(row) ? selectedItems : [items[row]]
        }

        private var selectedItems: [FileItem] {
            guard let table else { return [] }
            return table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0] : nil }
        }

        @objc func openClicked(_ sender: NSTableView) {
            guard sender.clickedRow >= 0 else { return }
            parent.model.open(targets(clickedRow: sender.clickedRow))
        }

        func openSelection() {
            parent.model.open(selectedItems)
        }

        private var menuTargets: [FileItem] = []

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            menuTargets = targets(clickedRow: table.clickedRow)
            guard !menuTargets.isEmpty else { return }
            let count = menuTargets.count
            menu.addItem(item("열기", #selector(menuOpen)))
            menu.addItem(item("Finder에서 보기", #selector(menuReveal)))
            menu.addItem(item("훑어보기", #selector(menuQuickLook)))
            menu.addItem(.separator())
            menu.addItem(item(count == 1 ? "경로 복사" : "경로 \(count)개 복사", #selector(menuCopyPaths)))
            menu.addItem(.separator())
            menu.addItem(item("휴지통으로 이동", #selector(menuTrash)))
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func menuOpen() { parent.model.open(menuTargets) }
        @objc private func menuReveal() { parent.model.revealInFinder(menuTargets) }
        @objc private func menuQuickLook() { parent.quickLookURL = menuTargets.first?.url }
        @objc private func menuCopyPaths() { parent.model.copyPaths(menuTargets) }
        @objc private func menuTrash() {
            let targets = menuTargets
            Task { await parent.model.moveToTrash(targets) }
        }
    }
}

/// 스페이스(훑어보기)와 Return(열기)을 받는 표.
final class ResultsNSTableView: NSTableView {
    var onSpace: (() -> Void)?
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 49:
                onSpace?()
                return
            case 36, 76:
                onReturn?()
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

private final class ResultCell: NSTableCellView {
    private let column: ResultsTableView.Column
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init(column: ResultsTableView.Column) {
        self.column = column
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(column.rawValue)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = column == .name ? .labelColor : .secondaryLabelColor
        switch column {
        case .name: label.lineBreakMode = .byTruncatingMiddle
        case .location: label.lineBreakMode = .byTruncatingHead
        default: label.lineBreakMode = .byTruncatingTail
        }
        if column == .size {
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        addSubview(label)
        textField = label

        var constraints = [
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ]
        if column == .name {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyUpOrDown
            addSubview(icon)
            imageView = icon
            constraints += [
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) {
        fatalError("코드로만 만든다")
    }

    func configure(_ item: FileItem) {
        switch column {
        case .name:
            label.stringValue = item.name
            icon.image = IconProvider.icon(for: item)
            toolTip = item.displayPath
        case .location:
            label.stringValue = item.parentDisplayPath
        case .size:
            label.stringValue = item.sizeText
        case .modified:
            label.stringValue = DateText.short(item.modified)
        case .kind:
            label.stringValue = item.kindDescription
        }
    }
}
