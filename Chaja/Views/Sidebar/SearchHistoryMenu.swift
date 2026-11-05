import SwiftUI

/// 검색창 옆 시계 버튼. 최근 검색과 저장된 검색을 바로 불러온다.
struct SearchHistoryMenu: View {
    @Bindable var model: SearchModel

    var body: some View {
        Menu {
            Button("현재 검색 저장…", systemImage: "bookmark") { model.isPresentingSaveSearch = true }
                .disabled(!model.criteria.hasConditions)

            Section("최근 검색") {
                if model.library.recent.isEmpty {
                    Text("최근 검색이 없어요")
                } else {
                    ForEach(model.library.recent) { recent in
                        Button {
                            model.apply(recent.criteria)
                        } label: {
                            Text(recent.criteria.summary)
                            Text(DateText.short(recent.date))
                        }
                    }
                    Button("최근 검색 지우기", role: .destructive) { model.library.clearRecent() }
                }
            }

            if !model.library.saved.isEmpty {
                Section("저장된 검색") {
                    ForEach(model.library.saved) { saved in
                        Button {
                            model.apply(saved.criteria)
                        } label: {
                            Text(saved.name)
                            Text(saved.criteria.summary)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("최근 검색 · 저장된 검색")
    }
}
