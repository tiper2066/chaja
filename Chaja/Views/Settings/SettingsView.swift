import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("일반", systemImage: "gearshape") { GeneralSettings() }
            Tab("제외 폴더", systemImage: "folder.badge.minus") { ExclusionSettings() }
        }
        .frame(width: 520, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.resultLimit) private var resultLimit = SearchModel.defaultResultLimit
    @AppStorage(AppSettings.Key.hotKeyEnabled) private var hotKeyEnabled = true
    @State private var hotKey = AppSettings.hotKey
    @State private var hotKeyFailed = HotKeyService.shared.registrationFailed
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var defaultScope = AppSettings.defaultScope
    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            Section {
                Toggle("전역 단축키 사용", isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { reregisterHotKey() }
                LabeledContent("단축키") {
                    HotKeyRecorder(hotKey: $hotKey)
                        .disabled(!hotKeyEnabled)
                        .onChange(of: hotKey) {
                            AppSettings.hotKey = hotKey
                            reregisterHotKey()
                        }
                }
                if hotKeyFailed && hotKeyEnabled {
                    Label("다른 앱이 이미 쓰는 조합이에요. 다른 키를 골라주세요.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            } footer: {
                Text("어느 앱에서든 이 키를 누르면 Chaja가 앞으로 나오고 검색창에 커서가 놓입니다. 다시 누르면 숨겨요.")
                    .settingsFooter()
            }

            Section {
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError).foregroundStyle(.red).font(.callout)
                }
            }

            Section {
                Picker("결과 최대 개수", selection: $resultLimit) {
                    ForEach(AppSettings.resultLimitOptions, id: \.self) { Text("\($0.formatted())개").tag($0) }
                }
                Picker("기본 검색 위치", selection: $defaultScope) {
                    ForEach(SearchScope.presets, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    if defaultScope.isCustomFolder {
                        Label(defaultScope.title, systemImage: defaultScope.symbol).tag(defaultScope)
                    }
                }
                .onChange(of: defaultScope) { AppSettings.defaultScope = defaultScope }
                Button("다른 폴더를 기본 위치로…") { isChoosingFolder = true }
            } footer: {
                Text("결과가 많을수록 표시가 느려질 수 있어요. 기본 위치는 앱을 열거나 필터를 초기화할 때 적용됩니다.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { defaultScope = .folder(url) }
        }
    }

    private func reregisterHotKey() {
        HotKeyService.shared.applySettings()
        hotKeyFailed = HotKeyService.shared.registrationFailed
    }
}

private struct ExclusionSettings: View {
    @AppStorage(AppSettings.Key.excludedFolders) private var excludedFoldersText = AppSettings.defaultExcludedFoldersText
    @State private var newEntry = ""
    @State private var selection: String?
    @State private var isChoosingFolder = false

    private var entries: [String] { AppSettings.entries(fromText: excludedFoldersText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 폴더 안의 파일은 결과에서 뺍니다. 이름만 쓰면(예: node_modules) 어디에 있든 제외하고, 경로를 쓰면(예: ~/Library/Caches) 그 위치만 제외해요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(entries, id: \.self) { entry in
                    Label(entry, systemImage: entry.hasPrefix("/") || entry.hasPrefix("~") ? "folder" : "textformat")
                        .tag(entry)
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .onDeleteCommand(perform: removeSelected)

            HStack(spacing: 6) {
                TextField("폴더 이름 또는 경로", text: $newEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addEntry)
                Button("추가", action: addEntry)
                    .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("폴더 선택…") { isChoosingFolder = true }
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .help("선택한 항목 삭제")
            }

            HStack {
                Spacer()
                Button("기본값으로 되돌리기") { excludedFoldersText = AppSettings.defaultExcludedFoldersText }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                add((url.path as NSString).abbreviatingWithTildeInPath)
            }
        }
    }

    private func addEntry() {
        add(newEntry)
        newEntry = ""
    }

    private func add(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !entries.contains(trimmed) else { return }
        excludedFoldersText = (entries + [trimmed]).joined(separator: "\n")
    }

    private func removeSelected() {
        guard let selection else { return }
        excludedFoldersText = entries.filter { $0 != selection }.joined(separator: "\n")
        self.selection = nil
    }
}

/// 클릭한 뒤 원하는 조합을 누르면 기록된다. Esc는 취소.
private struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "키 조합을 누르세요…" : hotKey.displayString)
                    .monospaced(!isRecording)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            if hotKey != .defaultValue && !isRecording {
                Button("기본값") { hotKey = .defaultValue }
                    .buttonStyle(.link)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        isRecording = true
        hint = nil
        // 등록된 전역 단축키는 키 입력을 가로채므로, 같은 조합도 기록할 수 있게 잠시 해제한다.
        HotKeyService.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stopRecording()
                return nil
            }
            if let recorded = HotKey(event: event) {
                hotKey = recorded
                stopRecording()
            } else {
                hint = "⌘ ⌥ ⌃ 중 하나와 함께 눌러주세요"
            }
            return nil
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotKeyService.shared.applySettings()
    }
}

private extension Text {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
