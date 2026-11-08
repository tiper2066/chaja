import QuickLook
import SwiftUI

struct ContentView: View {
    @Bindable var model: SearchModel
    let analysis: AnalysisCenter
    @AppStorage("resultsLayout") private var layout: ResultsLayout = .list
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("didShowAccessGuide") private var didShowAccessGuide = false
    @State private var showAccessGuide = false
    @State private var saveName = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            FilterSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 270, ideal: 290, max: 360)
        } detail: {
            ResultsView(model: model, layout: layout, quickLookURL: $model.quickLookURL)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model, quickLookURL: $model.quickLookURL)
                        .inspectorColumnWidth(min: 250, ideal: 290, max: 380)
                }
        }
        .navigationTitle("Chaja")
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .quickLookPreview($model.quickLookURL)
        .onChange(of: model.criteria) { model.scheduleSearch() }
        .onAppear {
            if !didShowAccessGuide && !model.hasFullDiskAccess { showAccessGuide = true }
            let openWindow = openWindow
            MainWindow.open = { openWindow(id: MainWindow.id) }
            HotKeyService.shared.onPress = { [model] in
                MainWindow.toggle { model.requestSearchFocus() }
            }
            model.loadTags()
        }
        .alert("현재 검색 저장", isPresented: $model.isPresentingSaveSearch) {
            TextField("이름", text: $saveName, prompt: Text(model.criteria.summary))
            Button("저장") {
                model.saveCurrentSearch(named: saveName)
                saveName = ""
            }
            Button("취소", role: .cancel) { saveName = "" }
        } message: {
            Text("저장한 검색은 사이드바 맨 위와 ‘검색’ 메뉴(⌘1~9)에서 바로 불러올 수 있어요.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
        .sheet(isPresented: $showAccessGuide) {
            FullDiskAccessView(hasAccess: model.hasFullDiskAccess) {
                didShowAccessGuide = true
                showAccessGuide = false
            }
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .idle: ""
        case .searching: "찾는 중… \(model.results.count.formatted())개"
        case .finished: "\(model.results.count.formatted())개\(model.reachedLimit ? " 이상" : "") 항목"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("보기", selection: $layout) {
                Label("리스트", systemImage: "list.bullet").tag(ResultsLayout.list)
                Label("그리드", systemImage: "square.grid.2x2").tag(ResultsLayout.grid)
            }
            .pickerStyle(.segmented)
            .help("보기 방식")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("정렬 기준", selection: $model.sortField) {
                    ForEach(SearchModel.SortField.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("순서", selection: $model.sortAscending) {
                    Text("오름차순").tag(true)
                    Text("내림차순").tag(false)
                }
                .pickerStyle(.inline)
            } label: {
                Label("정렬", systemImage: "arrow.up.arrow.down")
            }
            .help("정렬")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(AnalysisTool.allCases) { tool in
                    Button("\(tool.title) 찾기…", systemImage: tool.symbol) {
                        analysis.tool = tool
                        openWindow(id: AnalysisCenter.windowID)
                    }
                }
            } label: {
                Label("분석", systemImage: "square.on.square.dashed")
            }
            .help("중복 파일 · 비슷한 이미지 찾기")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("미리보기", systemImage: "sidebar.trailing")
            }
            .help("미리보기 패널 보기/숨기기")
        }
    }
}

struct FullDiskAccessView: View {
    let hasAccess: Bool
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Chaja에 오신 걸 환영해요")
                .font(.title2.bold())
            Text("Chaja는 Spotlight 인덱스로 맥 전체를 빠르게 찾아요.\n숨김 파일이나 보호된 폴더까지 찾으려면 ‘전체 디스크 접근 권한’을 켜주세요.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Label("시스템 설정 > 개인정보 보호 및 보안 > 전체 디스크 접근 권한", systemImage: "1.circle")
                Label("목록에서 Chaja를 켜기 (없으면 + 버튼으로 추가)", systemImage: "2.circle")
                Label("Chaja로 돌아오면 자동으로 확인해요", systemImage: "3.circle")
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if hasAccess {
                Label("권한이 켜져 있어요", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            HStack {
                Button("나중에", action: onDone)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if hasAccess {
                    Button("시작하기", action: onDone)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                } else {
                    Button("시스템 설정 열기", action: PermissionService.openFullDiskAccessSettings)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

#Preview {
    ContentView(model: SearchModel(), analysis: AnalysisCenter())
}
