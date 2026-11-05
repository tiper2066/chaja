import SwiftUI

enum ResultsLayout: String {
    case list, grid
}

struct ResultsView: View {
    @Bindable var model: SearchModel
    let layout: ResultsLayout
    @Binding var quickLookURL: URL?

    var body: some View {
        Group {
            if model.results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if model.reachedLimit { limitBanner }
                    switch layout {
                    case .list: ResultsTable(model: model, quickLookURL: $quickLookURL)
                    case .grid: ResultsGrid(model: model, quickLookURL: $quickLookURL)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model) }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.phase {
        case .searching:
            ProgressView("찾는 중…")
                .controlSize(.large)
        case .finished:
            ContentUnavailableView {
                Label("조건에 맞는 파일이 없어요", systemImage: "magnifyingglass")
            } description: {
                Text("다른 키워드나 필터로 다시 시도해보세요.\n숨김 파일이라면 ‘숨김 파일 포함’을 켜보세요.")
            } actions: {
                Button("필터 초기화", action: model.resetFilters)
            }
        case .idle:
            ContentUnavailableView {
                Label("무엇을 찾을까요?", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("왼쪽에서 이름, 확장자, 종류, 크기, 날짜를 고르면 바로 찾아요.\n여러 조건을 고르면 모두 만족하는 파일만 보여줘요.")
            }
        }
    }

    private var limitBanner: some View {
        Label("결과가 많아 처음 \(model.results.count.formatted())개만 보여줘요. 조건을 좁혀보세요.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.08))
    }
}

struct FileContextMenu: View {
    let model: SearchModel
    let items: [FileItem]
    @Binding var quickLookURL: URL?

    var body: some View {
        if !items.isEmpty {
            Button("열기") { model.open(items) }
            Button("Finder에서 보기") { model.revealInFinder(items) }
            Button("훑어보기") { quickLookURL = items.first?.url }
            Divider()
            Button(items.count == 1 ? "경로 복사" : "경로 \(items.count)개 복사") { model.copyPaths(items) }
            Divider()
            Button("휴지통으로 이동", role: .destructive) {
                Task { await model.moveToTrash(items) }
            }
        }
    }
}

struct StatusBar: View {
    let model: SearchModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.phase == .searching ? .orange : .green)
                    .frame(width: 7, height: 7)
                Text(engineText)
            }
            if let elapsed = model.elapsed {
                Text("완료 \(elapsed.secondsText)")
                if let first = model.firstResultElapsed {
                    Text("첫 결과 \(first.secondsText)")
                }
            }
            Spacer()
            Text(selectionText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var engineText: String {
        model.isScanningDisk ? "Spotlight 인덱스 + 디스크 직접 검색 중" : "Spotlight 인덱스 사용 중"
    }

    private var selectionText: String {
        let selected = model.selectedItems
        switch selected.count {
        case 0: return "항목을 선택하세요"
        case 1: return "선택: \(selected[0].name)"
        default:
            let total = selected.compactMap(\.size).reduce(0, +)
            return "\(selected.count)개 선택 • \(total.formatted(.byteCount(style: .file)))"
        }
    }
}
