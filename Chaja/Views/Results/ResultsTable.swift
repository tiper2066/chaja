import SwiftUI

struct ResultsTable: View {
    @Bindable var model: SearchModel
    @Binding var quickLookURL: URL?

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("이름", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    Image(nsImage: IconProvider.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(item.displayPath)
            }
            .width(min: 180, ideal: 320)

            TableColumn("위치", value: \.parentDisplayPath, comparator: .localizedStandard) { item in
                Text(item.parentDisplayPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 260)

            TableColumn("크기", value: \.sortSize) { item in
                Text(item.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80, max: 110)

            TableColumn("수정일", value: \.sortModified) { item in
                Text(DateText.short(item.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150, max: 200)

            TableColumn("종류", value: \.kindDescription, comparator: .localizedStandard) { item in
                Text(item.kindDescription)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130, max: 220)
        } rows: {
            ForEach(model.results) { item in
                TableRow(item)
                    .draggable(item.url)
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { ids in
            FileContextMenu(model: model, items: model.items(for: ids), quickLookURL: $quickLookURL)
        } primaryAction: { ids in
            model.open(model.items(for: ids))
        }
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
    }
}
