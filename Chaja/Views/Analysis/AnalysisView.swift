import QuickLook
import SwiftUI

/// 중복 파일 찾기 / 비슷한 이미지 찾기 창.
struct AnalysisView: View {
    @Bindable var center: AnalysisCenter
    let search: SearchModel
    @State private var quickLookURL: URL?

    var body: some View {
        AnalysisSessionView(session: center.session(for: center.tool), search: search,
                            quickLookURL: $quickLookURL, onTrashed: didTrash)
            .id(center.tool)
            .navigationTitle("\(center.tool.title) 찾기")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("분석", selection: $center.tool) {
                        ForEach(AnalysisTool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .quickLookPreview($quickLookURL)
    }

    private func didTrash(_ paths: Set<String>) {
        search.removeResults(paths: paths)
        center.duplicates.remove(paths: paths)
        center.similarImages.remove(paths: paths)
    }
}

private struct AnalysisSessionView: View {
    @Bindable var session: AnalysisSession
    let search: SearchModel
    @Binding var quickLookURL: URL?
    let onTrashed: (Set<String>) -> Void
    @State private var isChoosingFolder = false
    @State private var isConfirmingTrash = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !session.groups.isEmpty {
                Divider()
                footer
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { session.target = .folder(url) }
        }
        .confirmationDialog("\(session.marked.count.formatted())개 파일을 휴지통으로 옮길까요?",
                            isPresented: $isConfirmingTrash) {
            Button("휴지통으로 이동 (\(session.markedBytes.formatted(.byteCount(style: .file))))", role: .destructive) {
                Task { onTrashed(await session.trashMarked()) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("표시하지 않은 파일은 그대로 남아요. 옮긴 파일은 휴지통에서 되살릴 수 있어요.")
        }
    }

    // MARK: - 상단 조건

    private var candidates: [FileItem] {
        search.results.filter { !$0.isFolder && (session.tool == .duplicates || $0.kind == .image) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("대상", selection: $session.target) {
                Text("현재 검색 결과 (\(candidates.count.formatted())개)").tag(AnalysisTarget.searchResults)
                if case .folder(let url) = session.target {
                    Label(url.lastPathComponent, systemImage: "folder").tag(session.target)
                }
            }
            .fixedSize()
            Button("폴더 선택…") { isChoosingFolder = true }

            Divider().frame(height: 18)

            switch session.tool {
            case .duplicates:
                Picker("최소 크기", selection: $session.minimumSize) {
                    ForEach(DuplicateMinimumSize.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
            case .similarImages:
                Picker("비슷한 정도", selection: $session.similarity) {
                    ForEach(SimilarityLevel.allCases) { level in
                        Text("\(level.title) — \(level.detail)").tag(level)
                    }
                }
                .fixedSize()
            }

            Spacer()

            if session.phase == .running {
                Button("중지", systemImage: "stop.fill", action: session.cancel)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            } else {
                Button(session.phase == .finished ? "다시 찾기" : "찾기", systemImage: "magnifyingglass") {
                    session.start(searchResults: candidates, resultsTruncated: search.reachedLimit)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(session.target == .searchResults && candidates.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 본문

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .idle:
            ContentUnavailableView {
                Label(session.tool == .duplicates ? "내용이 똑같은 파일 찾기" : "비슷한 사진 찾기", systemImage: session.tool.symbol)
            } description: {
                Text(idleDescription)
            }
        case .running:
            if let progress = session.progress {
                VStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 320)
                    Text(progress.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .finished:
            if session.groups.isEmpty {
                ContentUnavailableView {
                    Label(session.tool == .duplicates ? "중복 파일이 없어요" : "비슷한 이미지가 없어요",
                          systemImage: "checkmark.circle")
                } description: {
                    Text(session.errorMessage ?? "\(session.examined.formatted())개 파일을 비교했어요.")
                }
            } else {
                VStack(spacing: 0) {
                    if let message = noticeMessage { notice(message) }
                    switch session.tool {
                    case .duplicates: DuplicateGroupList(session: session, quickLookURL: $quickLookURL)
                    case .similarImages: SimilarGroupList(session: session, quickLookURL: $quickLookURL)
                    }
                }
            }
        }
    }

    private var idleDescription: String {
        switch session.tool {
        case .duplicates:
            "크기가 같은 파일끼리 앞뒤 일부를 먼저 비교하고, 같아 보이는 파일만 전체 내용(SHA-256)을 비교해요.\n현재 검색 결과나 원하는 폴더를 골라 찾기를 누르세요."
        case .similarImages:
            "Vision이 사진마다 특징을 뽑아, 크기·화질이 다르거나 살짝 보정한 사진까지 묶어줘요.\n한 번 분석한 사진은 기억해 두어 다음엔 더 빨라요."
        }
    }

    private var noticeMessage: String? {
        var parts: [String] = []
        if session.wasTruncated {
            parts.append(session.target == .searchResults
                         ? "검색 결과가 상한에서 잘려 일부만 분석했어요. 조건을 좁히거나 폴더를 골라보세요."
                         : "파일이 너무 많아 일부만 분석했어요. 더 작은 폴더를 골라보세요.")
        }
        if let error = session.errorMessage { parts.append(error) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func notice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.08))
    }

    // MARK: - 하단

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("자동 표시") {
                switch session.tool {
                case .duplicates:
                    Button("가장 먼저 만든 파일만 남기기", action: session.keepFirstInEveryGroup)
                case .similarImages:
                    Button("가장 큰 파일만 남기기", action: session.keepFirstInEveryGroup)
                }
                Button("가장 최근에 수정한 파일만 남기기", action: session.keepNewestInEveryGroup)
                Divider()
                Button("표시 모두 해제", action: session.clearMarks)
            }
            .fixedSize()
            Button("휴지통으로 이동", systemImage: "trash") { isConfirmingTrash = true }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .disabled(session.marked.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var summary: String {
        let marked = session.marked.isEmpty
            ? "휴지통으로 보낼 파일을 표시하세요"
            : "\(session.marked.count.formatted())개 표시 • \(session.markedBytes.formatted(.byteCount(style: .file)))"
        switch session.tool {
        case .duplicates:
            return "중복 \(session.groups.count.formatted())묶음 • 사본 \(session.duplicateFileCount.formatted())개 — \(marked)"
        case .similarImages:
            let images = session.groups.reduce(0) { $0 + $1.files.count }
            return "비슷한 이미지 \(session.groups.count.formatted())묶음 • \(images.formatted())장 — \(marked)"
        }
    }

    private var detail: String {
        var parts = ["\(session.examined.formatted())개 비교"]
        if session.tool == .duplicates {
            parts.append("정리하면 최대 \(session.reclaimableBytes.formatted(.byteCount(style: .file))) 확보")
        }
        if session.skipped > 0 { parts.append("읽을 수 없거나 iCloud에만 있는 \(session.skipped.formatted())개 건너뜀") }
        if let elapsed = session.elapsed { parts.append(elapsed.secondsText) }
        return parts.joined(separator: " • ")
    }
}

// MARK: - 중복 파일 목록

private struct DuplicateGroupList: View {
    let session: AnalysisSession
    @Binding var quickLookURL: URL?

    var body: some View {
        List {
            ForEach(session.groups) { group in
                Section {
                    ForEach(group.files) { file in
                        row(file, in: group)
                    }
                } header: {
                    HStack {
                        Text("\(group.files.first?.sizeText ?? "--") × \(group.files.count)개")
                        Spacer()
                        Text("\(DuplicateFinder.wastedBytes(group).formatted(.byteCount(style: .file))) 중복")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
    }

    private func row(_ file: FileItem, in group: FileGroup) -> some View {
        let isMarked = session.isMarked(file)
        return HStack(spacing: 10) {
            Toggle("휴지통으로 보내기", isOn: Binding(get: { isMarked }, set: { _ in session.toggleMark(file, in: group) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("체크한 파일을 휴지통으로 옮겨요")
            FileThumbnail(item: file, size: 28)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(isMarked, color: .secondary)
                Text(file.parentDisplayPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("생성 \(DateText.short(file.created))")
                Text("수정 \(DateText.short(file.modified))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            KeepBadge(isMarked: isMarked)
        }
        .padding(.vertical, 2)
        .opacity(isMarked ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(file.url) }
        .contextMenu { AnalysisFileMenu(session: session, file: file, group: group, quickLookURL: $quickLookURL) }
        .help(file.displayPath)
    }
}

// MARK: - 비슷한 이미지 목록

private struct SimilarGroupList: View {
    let session: AnalysisSession
    @Binding var quickLookURL: URL?

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 160), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(session.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(group.files.count)장")
                                .font(.system(size: 12, weight: .semibold))
                            Text(group.totalSize.formatted(.byteCount(style: .file)))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(group.files) { file in
                                cell(file, in: group)
                            }
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
        }
    }

    private func cell(_ file: FileItem, in group: FileGroup) -> some View {
        let isMarked = session.isMarked(file)
        return VStack(spacing: 4) {
            FileThumbnail(item: file, size: 112)
                .frame(width: 120, height: 112)
                .opacity(isMarked ? 0.4 : 1)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isMarked ? "trash.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(isMarked ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary),
                                         isMarked ? AnyShapeStyle(.red) : AnyShapeStyle(.clear))
                        .padding(4)
                }
            Text(file.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .strikethrough(isMarked, color: .secondary)
            Text("\(file.sizeText) • \(DateText.short(file.modified))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(isMarked ? Color.red.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(count: 2) { quickLookURL = file.url }
        .onTapGesture { session.toggleMark(file, in: group) }
        .contextMenu { AnalysisFileMenu(session: session, file: file, group: group, quickLookURL: $quickLookURL) }
        .help("\(file.displayPath)\n클릭: 휴지통으로 보낼 파일로 표시 • 두 번 클릭: 훑어보기")
    }
}

// MARK: - 공통

private struct KeepBadge: View {
    let isMarked: Bool

    var body: some View {
        Text(isMarked ? "삭제" : "남김")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isMarked ? .red : .green)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((isMarked ? Color.red : Color.green).opacity(0.12), in: Capsule())
            .frame(width: 44)
    }
}

private struct AnalysisFileMenu: View {
    let session: AnalysisSession
    let file: FileItem
    let group: FileGroup
    @Binding var quickLookURL: URL?

    var body: some View {
        Button("이 파일만 남기기") { session.keepOnly(file, in: group) }
        Button(session.isMarked(file) ? "남기기" : "휴지통으로 보낼 파일로 표시") { session.toggleMark(file, in: group) }
        Divider()
        Button("열기") { NSWorkspace.shared.open(file.url) }
        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        Button("훑어보기") { quickLookURL = file.url }
        Button("경로 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
    }
}
