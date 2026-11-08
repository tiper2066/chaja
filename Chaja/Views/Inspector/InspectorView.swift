import SwiftUI

struct InspectorView: View {
    let model: SearchModel
    @Binding var quickLookURL: URL?

    var body: some View {
        let selected = model.selectedItems
        Group {
            switch selected.count {
            case 0:
                ContentUnavailableView("항목을 선택하세요", systemImage: "sidebar.right",
                                       description: Text("결과에서 파일을 고르면 미리보기와 정보가 나타나요."))
            case 1:
                SingleItemInspector(model: model, item: selected[0], quickLookURL: $quickLookURL)
            default:
                MultipleItemsInspector(model: model, items: selected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SingleItemInspector: View {
    let model: SearchModel
    let item: FileItem
    @Binding var quickLookURL: URL?
    @State private var tags: [String] = []
    @State private var sources: [String] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                FileThumbnail(item: item, size: 160)
                    .frame(height: 170)
                    .onTapGesture(count: 2) { quickLookURL = item.url }

                VStack(spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                    Text(item.kindDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Button {
                        model.revealInFinder([item])
                    } label: {
                        Label("Finder에서 보기", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)

                    HStack(spacing: 8) {
                        Button {
                            model.open([item])
                        } label: {
                            Label("열기", systemImage: "arrow.up.forward.app")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            quickLookURL = item.url
                        } label: {
                            Label("훑어보기", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            model.copyPaths([item])
                        } label: {
                            Label("경로", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .help("경로 복사")
                    }
                    .buttonStyle(.glass)
                }

                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                    infoRow("위치", item.parentDisplayPath, symbol: "folder")
                    infoRow("크기", sizeDetail, symbol: "scalemass")
                    infoRow("생성일", DateText.full(item.created), symbol: "calendar.badge.plus")
                    infoRow("수정일", DateText.full(item.modified), symbol: "clock")
                    infoRow("종류", item.kindDescription, symbol: "tag")
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)

                if !tags.isEmpty {
                    InspectorSection(title: "태그", symbol: "tag") {
                        FlowLayout {
                            ForEach(tags, id: \.self) { tag in
                                Chip(title: tag, symbol: "circle.fill", tint: tagColor(tag),
                                     isOn: model.criteria.tags.contains(tag)) {
                                    model.criteria.tags.formSymmetricDifference([tag])
                                }
                                .help("이 태그로 찾기")
                            }
                        }
                    }
                }

                if !sources.isEmpty {
                    InspectorSection(title: "다운로드 출처", symbol: "arrow.down.circle") {
                        ForEach(sources, id: \.self) { source in
                            sourceRow(source)
                        }
                    }
                }

                FileInsightsView(item: item, quickLookURL: $quickLookURL)
            }
            .padding(16)
        }
        .task(id: item.id) {
            let url = item.url
            let loaded = await Task.detached { (FileMetadata.tags(of: url), FileMetadata.whereFroms(of: url)) }.value
            tags = loaded.0
            sources = loaded.1
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: String) -> some View {
        let url = URL(string: source)
        HStack(spacing: 6) {
            if let url, url.scheme?.hasPrefix("http") == true {
                Link(url.host() ?? source, destination: url)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(source)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let host = url?.host() {
                Button {
                    model.criteria.whereFrom = host
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("\(host)에서 받은 파일 찾기")
            }
        }
        .font(.system(size: 12))
        .help(source)
    }

    private func tagColor(_ name: String) -> Color {
        model.availableTags.first { $0.name == name }?.color.map(Color.init(nsColor:)) ?? .secondary
    }

    private var sizeDetail: String {
        guard let size = item.size else { return "--" }
        return "\(item.sizeText) (\(size.formatted())바이트)"
    }

    private func infoRow(_ title: String, _ value: String, symbol: String) -> some View {
        GridRow {
            Label(title, systemImage: symbol)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MultipleItemsInspector: View {
    let model: SearchModel
    let items: [FileItem]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    Image(nsImage: IconProvider.icon(for: item))
                        .resizable()
                        .frame(width: 96, height: 96)
                        .rotationEffect(.degrees(Double(index - 1) * 8))
                        .offset(x: CGFloat(index - 1) * 14)
                }
            }
            .frame(height: 130)

            VStack(spacing: 4) {
                Text("\(items.count.formatted())개 항목").font(.headline)
                Text(items.compactMap(\.size).reduce(0, +).formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Button {
                    model.revealInFinder(items)
                } label: {
                    Label("Finder에서 보기", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Button {
                    model.copyPaths(items)
                } label: {
                    Label("경로 \(items.count)개 복사", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            Spacer()
        }
        .padding(16)
    }
}
