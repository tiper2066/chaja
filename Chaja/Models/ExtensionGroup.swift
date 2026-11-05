import Foundation

nonisolated struct ExtensionGroup: Identifiable, Hashable, Sendable {
    let id: String
    let extensions: [String]

    static let presets: [ExtensionGroup] = [
        ExtensionGroup(id: ".pdf", extensions: ["pdf"]),
        ExtensionGroup(id: ".jpg/.png", extensions: ["jpg", "jpeg", "png", "heic", "webp", "gif"]),
        ExtensionGroup(id: ".mov/.mp4", extensions: ["mov", "mp4", "m4v"]),
        ExtensionGroup(id: ".docx/.hwp", extensions: ["docx", "doc", "hwp", "hwpx", "pages"]),
        ExtensionGroup(id: ".xlsx", extensions: ["xlsx", "xls", "numbers", "csv"]),
        ExtensionGroup(id: ".pptx", extensions: ["pptx", "ppt", "key"]),
        ExtensionGroup(id: ".swift/.js", extensions: ["swift", "js", "ts", "tsx", "py", "sh"]),
        ExtensionGroup(id: ".zip", extensions: ["zip", "tar", "gz", "7z", "rar", "dmg"]),
    ]

    static func preset(id: String) -> ExtensionGroup? {
        presets.first { $0.id == id }
    }

    /// 사용자가 입력한 확장자 문자열을 정리한다. ".PDF, sketch" → ["pdf", "sketch"]
    static func normalize(_ input: String) -> [String] {
        input
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".*")).lowercased() }
            .filter { !$0.isEmpty }
    }
}
