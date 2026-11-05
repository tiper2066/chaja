import SwiftUI

struct ResultsGrid: View {
    @Bindable var model: SearchModel
    @Binding var quickLookURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.results) { item in
                    GridCell(item: item, isSelected: model.selection.contains(item.id))
                        .onTapGesture(count: 2) { model.open([item]) }
                        .onTapGesture { select(item) }
                        .contextMenu {
                            let targets = model.selection.contains(item.id) ? model.selectedItems : [item]
                            FileContextMenu(model: model, items: targets, quickLookURL: $quickLookURL)
                        }
                        .draggable(item.url)
                }
            }
            .padding(14)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            model.toggleQuickLook()
            return .handled
        }
    }

    private func select(_ item: FileItem) {
        if NSEvent.modifierFlags.contains(.command) {
            model.selection.formSymmetricDifference([item.id])
        } else {
            model.selection = [item.id]
        }
    }
}

private struct GridCell: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(item: item, size: 64)
                .frame(width: 72, height: 72)
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
            Text("\(item.sizeText) • \(DateText.short(item.modified))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .top)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(item.displayPath)
    }
}

struct FileThumbnail: View {
    let item: FileItem
    let size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? IconProvider.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: item.id) {
                thumbnail = nil
                guard ThumbnailProvider.supportsThumbnail(item) else { return }
                thumbnail = await ThumbnailProvider.thumbnail(for: item, size: size)
            }
    }
}
