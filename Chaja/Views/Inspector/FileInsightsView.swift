import SwiftUI

/// 인스펙터의 분석 카드: 맥 전체에서 내용이 같은 파일, 같은 폴더의 비슷한 이미지.
struct FileInsightsView: View {
    let item: FileItem
    @Binding var quickLookURL: URL?
    @State private var duplicates: Check = .checking
    @State private var similar: Check = .checking

    /// 같은 크기 후보가 이보다 많으면 일부만 비교한다(작은 파일은 같은 크기가 흔하다).
    private static let sameSizeLimit = 1_000
    private static let previewCount = 5

    enum Check {
        case checking
        case done([FileItem], partial: Bool = false)
        case unavailable

        var isAvailable: Bool {
            if case .unavailable = self { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if duplicates.isAvailable {
                InspectorSection(title: "중복 파일", symbol: "doc.on.doc") { duplicatesContent }
            }
            if similar.isAvailable {
                InspectorSection(title: "비슷한 이미지", symbol: "photo.on.rectangle.angled") { similarContent }
            }
        }
        .task(id: item.id) { await checkDuplicates() }
        .task(id: item.id) { await checkSimilarImages() }
    }

    // MARK: - 중복 파일

    @ViewBuilder
    private var duplicatesContent: some View {
        switch duplicates {
        case .checking:
            progressRow("맥에서 같은 파일 찾는 중…")
        case .done(let files, let partial) where files.isEmpty:
            note(partial ? "같은 크기 파일이 많아 일부만 비교했는데, 같은 파일은 없었어요." : "맥에 내용이 같은 파일이 없어요.")
        case .done(let files, let partial):
            let wasted = (item.size ?? 0) * Int64(files.count)
            Text("내용이 같은 파일 \(files.count.formatted())개 • \(wasted.formatted(.byteCount(style: .file))) 차지")
                .font(.system(size: 12, weight: .medium))
            ForEach(files.prefix(Self.previewCount)) { file in
                duplicateRow(file)
            }
            if files.count > Self.previewCount {
                note("외 \((files.count - Self.previewCount).formatted())개")
            }
            if partial { note("같은 크기 파일이 많아 일부만 비교했어요.") }
        case .unavailable:
            EmptyView()
        }
    }

    private func duplicateRow(_ file: FileItem) -> some View {
        HStack(spacing: 6) {
            Image(nsImage: IconProvider.icon(for: file))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.parentDisplayPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Finder에서 보기")
        }
        .font(.system(size: 11))
        .help(file.displayPath)
        .contextMenu { fileMenu(file) }
    }

    private func checkDuplicates() async {
        duplicates = .checking
        guard !item.isFolder, let stat = FileStat(path: item.path), stat.isRegularFile, stat.size > 0 else {
            duplicates = .unavailable
            return
        }
        // 선택을 빠르게 옮기는 동안에는 찾지 않는다.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        let (candidates, partial) = await SpotlightSearchEngine.collect(
            queryString: "kMDItemFSSize == \(stat.size)", limit: Self.sameSizeLimit
        )
        guard !Task.isCancelled else { return }
        let exclusions = AppSettings.exclusionRules
        let others = candidates.filter {
            $0.path != item.path && !FileMatcher.isHiddenPath($0.path) && !exclusions.excludes(path: $0.path)
        }
        guard !others.isEmpty else {
            duplicates = .done([], partial: partial)
            return
        }
        guard let report = try? await DuplicateFinder.findDuplicates(in: [item] + others), !Task.isCancelled else { return }
        let group = report.groups.first { $0.files.contains { $0.path == item.path } }
        duplicates = .done(group?.files.filter { $0.path != item.path } ?? [], partial: partial)
    }

    // MARK: - 비슷한 이미지

    @ViewBuilder
    private var similarContent: some View {
        switch similar {
        case .checking:
            progressRow("같은 폴더에서 찾는 중…")
        case .done(let files, _) where files.isEmpty:
            note("같은 폴더에 비슷한 이미지가 없어요.")
        case .done(let files, _):
            Text("같은 폴더에 \(files.count.formatted())장")
                .font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 90), spacing: 6)], spacing: 6) {
                ForEach(files.prefix(9)) { file in
                    FileThumbnail(item: file, size: 60)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                        .onTapGesture { quickLookURL = file.url }
                        .help("\(file.name)\n클릭: 훑어보기")
                        .contextMenu { fileMenu(file) }
                }
            }
            if files.count > 9 { note("외 \((files.count - 9).formatted())장") }
        case .unavailable:
            EmptyView()
        }
    }

    private func checkSimilarImages() async {
        similar = .checking
        guard item.kind == .image else {
            similar = .unavailable
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        guard let found = try? await SimilarImageFinder.imagesInSameFolder(similarTo: item, level: .similar),
              !Task.isCancelled else { return }
        similar = .done(found)
    }

    // MARK: - 구성 요소

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func fileMenu(_ file: FileItem) -> some View {
        Button("열기") { NSWorkspace.shared.open(file.url) }
        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("훑어보기") { quickLookURL = file.url }
    }
}

/// 인스펙터 아래쪽의 제목 달린 정보 묶음.
struct InspectorSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
