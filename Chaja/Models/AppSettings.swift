import Foundation

/// UserDefaults에 저장하는 앱 설정. 설정 화면은 `@AppStorage`로 같은 키를 쓴다.
enum AppSettings {
    enum Key {
        static let resultLimit = "resultLimit"
        static let excludedFolders = "excludedFolders"
        static let defaultScope = "defaultScope"
        static let hotKey = "hotKey"
        static let hotKeyEnabled = "hotKeyEnabled"
    }

    static let resultLimitOptions = [1_000, 5_000, 10_000, 20_000, 50_000]

    private static var defaults: UserDefaults { .standard }

    static var resultLimit: Int {
        let value = defaults.integer(forKey: Key.resultLimit)
        return value > 0 ? value : SearchModel.defaultResultLimit
    }

    /// `@AppStorage`가 배열을 못 다뤄서 한 줄에 하나씩 이어 붙인 문자열로 저장한다.
    static let defaultExcludedFoldersText = ExclusionRules.defaultEntries.joined(separator: "\n")

    static var excludedFolders: [String] {
        get { entries(fromText: defaults.string(forKey: Key.excludedFolders) ?? defaultExcludedFoldersText) }
        set { defaults.set(newValue.joined(separator: "\n"), forKey: Key.excludedFolders) }
    }

    static func entries(fromText text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static var exclusionRules: ExclusionRules {
        ExclusionRules(entries: excludedFolders)
    }

    static var defaultScope: SearchScope {
        get { decode(SearchScope.self, forKey: Key.defaultScope) ?? .computer }
        set { encode(newValue, forKey: Key.defaultScope) }
    }

    static var hotKeyEnabled: Bool {
        get { defaults.object(forKey: Key.hotKeyEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.hotKeyEnabled) }
    }

    static var hotKey: HotKey {
        get { decode(HotKey.self, forKey: Key.hotKey) ?? .defaultValue }
        set { encode(newValue, forKey: Key.hotKey) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
