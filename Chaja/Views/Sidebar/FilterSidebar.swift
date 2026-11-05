import SwiftUI

struct FilterSidebar: View {
    @Bindable var model: SearchModel
    @State private var customExtensionInput = ""
    @State private var isChoosingFolder = false

    private var criteria: Binding<SearchCriteria> { $model.criteria }

    var body: some View {
        // 검색창·하단 버튼을 스크롤 영역 위에 겹치지 않도록 세 칸으로 나눈다.
        VStack(spacing: 0) {
            SearchField(text: criteria.text, prompt: "파일명 또는 내용",
                        focusRequest: model.searchFocusRequest, onSubmit: model.search)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    textTargetSection
                    extensionSection
                    kindSection
                    sizeSection
                    dateSection
                    optionsSection
                    locationSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
            Divider()
            searchFooter
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.criteria.scope = .folder(url)
            }
        }
    }

    // MARK: - 섹션

    private var textTargetSection: some View {
        Picker("검색 대상", selection: criteria.textTarget) {
            ForEach(SearchCriteria.TextTarget.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("‘이름 + 내용’은 PDF·Office·텍스트처럼 Spotlight가 본문을 색인한 파일에서 본문 단어도 찾습니다.")
    }

    private var extensionSection: some View {
        SidebarSection(title: "확장자") {
            if !model.criteria.extensionGroupIDs.isEmpty || !model.criteria.customExtensions.isEmpty {
                Button("초기화") {
                    model.criteria.extensionGroupIDs = []
                    model.criteria.customExtensions = []
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        } content: {
            FlowLayout {
                ForEach(ExtensionGroup.presets) { group in
                    Chip(title: group.id, isOn: model.criteria.extensionGroupIDs.contains(group.id)) {
                        model.criteria.extensionGroupIDs.formSymmetricDifference([group.id])
                    }
                    .help(group.extensions.map { ".\($0)" }.joined(separator: ", "))
                }
                ForEach(model.criteria.customExtensions, id: \.self) { ext in
                    Chip(title: ".\(ext)", symbol: "xmark", isOn: true) {
                        model.criteria.customExtensions.removeAll { $0 == ext }
                    }
                }
            }
            TextField("직접 입력 (예: sketch, fig)", text: $customExtensionInput)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(addCustomExtensions)
        }
    }

    private var kindSection: some View {
        SidebarSection(title: "파일 종류") {
            FlowLayout {
                ForEach(FileKind.allCases) { kind in
                    Chip(title: kind.title, symbol: kind.symbol, tint: kind.tint,
                         isOn: model.criteria.kinds.contains(kind)) {
                        model.criteria.kinds.formSymmetricDifference([kind])
                    }
                }
            }
        }
    }

    private var sizeSection: some View {
        SidebarSection(title: "크기", symbol: "scalemass") {
            HStack(spacing: 6) {
                sizeField("최소", value: criteria.minSizeMB)
                Text("~").foregroundStyle(.secondary)
                sizeField("최대", value: criteria.maxSizeMB)
                Text("MB").font(.caption).foregroundStyle(.secondary)
            }
            FlowLayout {
                sizePreset("~10MB", min: nil, max: 10)
                sizePreset("10~100MB", min: 10, max: 100)
                sizePreset("100MB+", min: 100, max: nil)
                sizePreset("1GB+", min: 1024, max: nil)
            }
        }
    }

    private var dateSection: some View {
        SidebarSection(title: "날짜", symbol: "calendar") {
            Picker("날짜 기준", selection: criteria.dateField) {
                ForEach(DateField.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        } content: {
            FlowLayout {
                ForEach(DatePreset.allCases) { preset in
                    Chip(title: preset.title, isOn: model.criteria.datePreset == preset) {
                        model.criteria.datePreset = preset
                    }
                }
            }
            if model.criteria.datePreset == .custom {
                HStack(spacing: 4) {
                    DatePicker("시작", selection: criteria.customStartDate, displayedComponents: .date)
                    Text("~").foregroundStyle(.secondary)
                    DatePicker("끝", selection: criteria.customEndDate, displayedComponents: .date)
                }
                .labelsHidden()
                .datePickerStyle(.field)
                .controlSize(.small)
            }
        }
    }

    private var optionsSection: some View {
        SidebarSection(title: "옵션") {
            VStack(alignment: .leading, spacing: 2) {
                optionToggle("숨김 파일 포함", detail: "점(.)으로 시작하는 파일까지", isOn: criteria.includeHidden)
                optionToggle("패키지 내용 검색", detail: "앱 등 패키지 내부까지", isOn: criteria.searchPackages)
                optionToggle("대소문자 구분", detail: "영문 대소문자를 정확히 일치", isOn: criteria.caseSensitive)
            }
            if model.criteria.needsDirectScan {
                directScanNotice
            }
        }
    }

    private var locationSection: some View {
        SidebarSection(title: "위치") {
            VStack(spacing: 2) {
                ForEach(SearchScope.presets, id: \.self) { scope in
                    locationRow(scope)
                }
                if model.criteria.scope.isCustomFolder {
                    locationRow(model.criteria.scope)
                }
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("폴더 선택…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private var searchFooter: some View {
        VStack(spacing: 6) {
            Button {
                if model.phase == .searching { model.cancel() } else { model.search() }
            } label: {
                Label(model.phase == .searching ? "검색 중지" : "찾기",
                      systemImage: model.phase == .searching ? "stop.fill" : "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!model.criteria.canSearch && model.phase != .searching)
            .help("지금 검색 (⌘↩)")

            HStack {
                Text(footerStatus)
                Spacer()
                if model.criteria != SearchCriteria() {
                    Button("필터 초기화", action: model.resetFilters)
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 구성 요소

    private var footerStatus: String {
        switch model.phase {
        case .idle:
            return model.criteria.canSearch ? "조건을 바꾸면 자동으로 찾아요" : "조건을 하나 이상 골라주세요"
        case .searching:
            return "찾는 중… \(model.results.count.formatted())개"
        case .finished:
            let count = model.reachedLimit ? "\(model.results.count.formatted())개 이상" : "\(model.results.count.formatted())개"
            return [model.elapsed?.secondsText, count].compactMap { $0 }.joined(separator: " • ")
        }
    }

    private var directScanNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("디스크를 직접 훑어서 찾기 때문에 시간이 더 걸려요.", systemImage: "info.circle")
            if !model.hasFullDiskAccess {
                Text("보호된 폴더까지 찾으려면 전체 디스크 접근 권한이 필요해요.")
                Button("시스템 설정 열기", action: PermissionService.openFullDiskAccessSettings)
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sizeField(_ title: String, value: Binding<Double?>) -> some View {
        TextField(title, value: value, format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .multilineTextAlignment(.trailing)
    }

    private func sizePreset(_ title: String, min: Double?, max: Double?) -> some View {
        Chip(title: title, isOn: model.criteria.minSizeMB == min && model.criteria.maxSizeMB == max) {
            if model.criteria.minSizeMB == min && model.criteria.maxSizeMB == max {
                model.criteria.minSizeMB = nil
                model.criteria.maxSizeMB = nil
            } else {
                model.criteria.minSizeMB = min
                model.criteria.maxSizeMB = max
            }
        }
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func locationRow(_ scope: SearchScope) -> some View {
        let isSelected = model.criteria.scope == scope
        return Button {
            model.criteria.scope = scope
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scope.symbol)
                    .frame(width: 16)
                Text(scope.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(scope.url?.path ?? "이 맥의 모든 볼륨")
    }

    private func addCustomExtensions() {
        let new = ExtensionGroup.normalize(customExtensionInput)
            .filter { !model.criteria.customExtensions.contains($0) }
        model.criteria.customExtensions.append(contentsOf: new)
        customExtensionInput = ""
    }
}
