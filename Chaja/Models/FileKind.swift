import SwiftUI
import UniformTypeIdentifiers

nonisolated enum FileKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case document, image, movie, audio, code, archive, folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .document: "문서"
        case .image: "이미지"
        case .movie: "동영상"
        case .audio: "오디오"
        case .code: "코드"
        case .archive: "압축"
        case .folder: "폴더"
        }
    }

    var symbol: String {
        switch self {
        case .document: "doc.text.fill"
        case .image: "photo.fill"
        case .movie: "film.fill"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox.fill"
        case .folder: "folder.fill"
        }
    }

    var tint: Color {
        switch self {
        case .document: .red
        case .image: .purple
        case .movie: .pink
        case .audio: .orange
        case .code: .green
        case .archive: .brown
        case .folder: .blue
        }
    }

    /// Spotlight 쿼리 조각. `.ts`(TypeScript)는 Spotlight가 MPEG-2 TS 동영상으로 분류하므로 동영상에서 빼고 코드에 넣는다.
    var queryClause: String {
        switch self {
        case .document:
            Self.anyOf([
                #"kMDItemContentTypeTree == "public.composite-content""#,
                #"kMDItemContentTypeTree == "public.presentation""#,
                #"kMDItemContentTypeTree == "public.spreadsheet""#,
                #"kMDItemContentType == "public.rtf""#,
                #"kMDItemContentType == "public.plain-text""#,
                #"kMDItemContentType == "net.daringfireball.markdown""#,
                #"kMDItemFSName == "*.hwp"c"#,
                #"kMDItemFSName == "*.hwpx"c"#,
            ])
        case .image:
            #"kMDItemContentTypeTree == "public.image""#
        case .movie:
            #"(kMDItemContentTypeTree == "public.movie" && kMDItemContentType != "public.mpeg-2-transport-stream")"#
        case .audio:
            #"kMDItemContentTypeTree == "public.audio""#
        case .code:
            Self.anyOf([
                #"kMDItemContentTypeTree == "public.source-code""#,
                #"kMDItemContentTypeTree == "public.script""#,
                #"kMDItemContentTypeTree == "public.json""#,
                #"kMDItemFSName == "*.ts"c"#,
                #"kMDItemFSName == "*.tsx"c"#,
            ])
        case .archive:
            Self.anyOf([
                #"kMDItemContentTypeTree == "public.archive""#,
                #"kMDItemContentTypeTree == "public.disk-image""#,
            ])
        case .folder:
            #"kMDItemContentType == "public.folder""#
        }
    }

    private static func anyOf(_ clauses: [String]) -> String {
        "(" + clauses.joined(separator: " || ") + ")"
    }

    private static let typeScriptExtensions: Set<String> = ["ts", "tsx", "mts", "cts"]
    private static let hangulDocumentExtensions: Set<String> = ["hwp", "hwpx"]

    /// 직접 스캔 결과와 화면 표시에 쓰는 분류. 쿼리 조각과 같은 기준을 따른다.
    static func classify(contentType identifier: String?, fileExtension: String) -> FileKind? {
        let ext = fileExtension.lowercased()
        if typeScriptExtensions.contains(ext) { return .code }
        if hangulDocumentExtensions.contains(ext) { return .document }
        guard let identifier, let type = UTType(identifier) else { return nil }

        if type == .folder { return .folder }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) { return .movie }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) { return .code }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .compositeContent) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type == .rtf || type == .plainText
            || type.identifier == "net.daringfireball.markdown" {
            return .document
        }
        return nil
    }
}
