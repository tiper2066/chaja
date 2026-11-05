import Foundation
import Testing
@testable import Chaja

/// 앱의 Spotlight 엔진 결과 수가 같은 쿼리의 `mdfind -count`와 같은지 확인한다.
@Suite(.serialized)
struct SpotlightIntegrationTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let scope: SearchScope
        let configure: @Sendable (inout SearchCriteria) -> Void
        var testDescription: String { label }
    }

    nonisolated static let cases: [Case] = [
        Case(label: "다운로드 전체", scope: .downloads) { _ in },
        Case(label: "홈의 PDF", scope: .home) { $0.extensionGroupIDs = [".pdf"] },
        Case(label: "홈의 문서 30일 이내 10MB 이하", scope: .home) {
            $0.kinds = [.document]; $0.datePreset = .last30Days; $0.maxSizeMB = 10
        },
        Case(label: "홈의 이미지 1MB 이상", scope: .home) { $0.kinds = [.image]; $0.minSizeMB = 1 },
        Case(label: "맥 전체 이름 '정산'", scope: .computer) { $0.text = "정산" },
        Case(label: "맥 전체 이름+내용 '정산'", scope: .computer) { $0.text = "정산"; $0.textTarget = .nameAndContent },
    ]

    @Test(arguments: cases)
    func engineMatchesMdfind(_ testCase: Case) async throws {
        var criteria = SearchCriteria()
        criteria.scope = testCase.scope
        testCase.configure(&criteria)
        let now = Date.now
        let queryString = SpotlightQueryBuilder.queryString(for: criteria, now: now)

        let expected = try mdfindCount(queryString, scope: testCase.scope)
        let actual = await engineCount(queryString, scope: testCase.scope)
        #expect(actual == expected, "\(queryString)")
    }

    /// 홈 폴더의 코드 파일은 수십만 개라, 상한에서 쿼리를 멈추지 않으면 1분 넘게 걸린다.
    @Test func broadQueryStopsAtLimitQuickly() async {
        var criteria = SearchCriteria()
        criteria.scope = .home
        criteria.kinds = [.code]
        let queryString = SpotlightQueryBuilder.queryString(for: criteria)

        let engine = SpotlightSearchEngine()
        let clock = ContinuousClock()
        var count = 0
        var reachedLimit = false
        var firstBatchAt: Duration?
        let start = clock.now
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engine.start(queryString: queryString, scope: criteria.scope, limit: SearchModel.defaultResultLimit,
                         onBatch: {
                             if firstBatchAt == nil { firstBatchAt = clock.now - start }
                             count += $0.count
                         },
                         onFinish: { reachedLimit = $0; continuation.resume() })
        }
        let total = clock.now - start
        print("넓은 검색: 첫 결과 \(firstBatchAt.map { "\($0)" } ?? "-"), 1만 개까지 \(total), 결과 \(count)개")
        #expect(reachedLimit)
        #expect(count == SearchModel.defaultResultLimit)
        #expect(total < .seconds(5))
    }

    private func engineCount(_ queryString: String, scope: SearchScope) async -> Int {
        let engine = SpotlightSearchEngine()
        var count = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let started = engine.start(queryString: queryString, scope: scope, limit: 1_000_000,
                                       onBatch: { count += $0.count },
                                       onFinish: { _ in continuation.resume() })
            if !started { continuation.resume() }
        }
        return count
    }

    private func mdfindCount(_ queryString: String, scope: SearchScope) throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        var arguments = ["-count"]
        if let url = scope.url { arguments += ["-onlyin", url.path] }
        process.arguments = arguments + [queryString]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
