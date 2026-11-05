# Chaja — 구현 계획 및 핸드오프 문서

> 새 세션에서 이어서 작업할 때 **이 문서를 먼저 끝까지 읽고**, 체크리스트에서 마지막으로 완료된 항목 다음부터 진행한다.
> 작업을 마칠 때마다 체크박스와 맨 아래 "작업 로그"를 갱신한다.

---

## 1. 개요

### 1.1 목표
맥 전체에서 원하는 파일을 여러 조건(이름·확장자·종류·크기·날짜 등)의 **AND 조합**으로 빠르게 찾는 심플한 macOS 네이티브 앱 **Chaja(차자)**.
문법 없이 토글과 칩만으로 조건을 만들고, Spotlight 인덱스를 직접 조회해 Finder 검색보다 빠르고 정확하게 찾는다.

### 1.2 확정된 결정 사항

| 항목 | 결정 |
|---|---|
| 사용 범위 | 본인 소유 맥북 프로 2대 (M2 / M5, 둘 다 24GB RAM, macOS 26) |
| 배포 방식 | 이 맥(M2)에서 빌드한 `Chaja.app`을 AirDrop/USB로 **복사 설치** |
| App Store | 출시 안 함 → **App Sandbox 끔** (맥 전체 검색 가능) |
| 코드 서명 | 로그인 키체인의 **자체 서명 인증서 `Chaja Self-Signed`**(SHA-1 `ECF48BC7…2D93`, 10년)로 서명. 서명 요구사항이 이 인증서에 고정되어 재빌드해도 권한 유지 |
| Hardened Runtime | **끔**. 자체 서명 인증서엔 Team ID가 없어 라이브러리 검증에 걸리고(앱 실행 실패), 공증도 안 하므로 불필요 |
| 최소 OS | **macOS 26 이상** (Liquid Glass 디자인) |
| 언어/UI | Swift 6 + SwiftUI (필요한 곳만 AppKit 브리지) |
| 검색 실행 | 필터 변경 시 **자동 갱신(디바운스)** + "찾기" 버튼 / Enter 도 유지 |
| "M5 가속" 표현 | **모두 제거**. "Spotlight 인덱스 사용 중" 등 사실대로 표기 |
| 설정 동기화 | **안 함** (맥마다 설정 따로 저장) |
| 추가 기능 | 전역 단축키, 검색 저장/최근 검색, 제외 폴더, 다운로드 출처 검색, Finder 태그 필터, 중복 파일 찾기, 비슷한 이미지 찾기 |

### 1.3 단계 요약

| 단계 | 내용 | 상태 |
|---|---|---|
| 0단계 | 개발 환경·프로젝트 뼈대·서명·아이콘 | ✅ 완료 (사용자 확인, 커밋 `6695318`) |
| 1단계 | 핵심 검색 앱 (시안 기능 + Spotlight + 직접 스캔 + Quick Look) | ✅ 완료 (사용자 확인) |
| 2단계 | 편의 기능 (단축키, 검색 저장, 제외 폴더, 다운로드 출처, 태그) + README | ✅ 완료 (사용자 확인) |
| 3단계 | 분석 기능 (중복 파일, 비슷한 이미지) | ⬜ 미착수 |
| 4단계 | 배포 (Release 빌드, M5 맥 설치 검증) | ⬜ 미착수 |

---

## 2. 사전 검토 결과 (요약)

### 2.1 개발 환경 (2026-11-05 확인)
- macOS 26.6 (25G72), Xcode 26.3 (17C529), Homebrew 설치됨 (`/opt/homebrew/bin/brew`)
- XcodeGen 2.46.0 설치됨 (0단계, 7.4MB)
- 코드 서명 인증서 `Chaja Self-Signed` 생성됨 (0단계). `security find-identity -p codesigning`에서 `CSSMERR_TP_NOT_TRUSTED`로 보이지만 자체 서명이라 정상이며 `codesign`/Xcode 서명은 잘 된다
- git 저장소 초기화됨 (0단계)
- Cursor Computer Use(화면 캡처)는 손쉬운 사용·화면 기록 권한이 없어 현재 사용 불가 → UI 확인은 사용자에게 요청
- Spotlight 인덱싱: `/`, `/System/Volumes/Data` 모두 활성
- ⚠️ Cursor 에이전트의 기본 샌드박스 셸에서는 `mdutil`/`mdfind`가 "Spotlight server is disabled"처럼 잘못 보인다. Spotlight 관련 명령과 앱 실행 테스트는 **샌드박스 밖(전체 권한)** 으로 실행할 것.

### 2.2 이 맥에서 측정한 Spotlight 속도 (`mdfind`, 프로세스 시작 시간 포함)

| 쿼리 | 결과 수 | 시간 |
|---|---|---|
| 이름에 "정산" 포함 (`'*정산*'cd`) | 5 | 0.19초 |
| 모든 PDF (`*.pdf`) | 1,185 | 0.7초 |
| PDF AND 최근 30일 AND 10MB 미만 | 22 | 0.58초 |
| 인덱스 전체 (`kMDItemFSSize >= 0`) | 약 1,859,962 | **82초** |

→ **결론:** 좁은 조건은 1초 이내. 결과가 수십만 개인 넓은 검색은 느리므로 **결과를 스트리밍 표시 + 표시 개수 상한**이 필수.

### 2.2.1 구현 중 확인한 Spotlight 사실 (1단계)
- 조건 없는 쿼리에 `kMDItemFSName == "*"`는 **0건**을 반환한다 → 전체는 `kMDItemContentTypeTree == "public.item"`
- `.ts`(TypeScript) 파일을 Spotlight가 `public.mpeg-2-transport-stream`(동영상)으로 분류한다. 홈 폴더 "동영상" 19만 개 중 실제 동영상은 5,947개 → 동영상 쿼리에서 제외하고 코드에 `*.ts`, `*.tsx` 이름 조건 추가 (진짜 MPEG-TS 동영상도 빠지는 부작용은 감수)
- `.docx`는 `public.composite-content`를 따른다 → 문서 종류의 기준
- 본문 검색: `kMDItemTextContent == "정산*"cdw`(단어 시작) 0.06초 vs `"*정산*"cd`(부분 일치) 1.16초, 결과 수 동일 → `cdw` 사용
- 이스케이프: 값 안의 `\`, `"`, `*`, `?` 앞에 `\`. 날짜는 `$time.iso(2026-10-01T00:00:00Z)`
- `/tmp`(`/private/tmp`)는 색인되지 않는다. Spotlight 실험용 파일은 `build/probe/`처럼 색인되는 곳에 만들 것
- **성능 핵심:** `NSMetadataItem.value(forAttribute:)`는 호출마다 Spotlight에 묻는다(1만 개 × 7속성 = 20.3초). `query.valueListAttributes`에 속성을 지정하고 `query.value(ofAttribute:forResultAt:)`로 읽으면 1.7초. 단 **`kMDItemPath`는 값 목록에 넣어도 nil**이라 경로만 항목에서 직접 읽는다

### 2.2.2 구현 중 확인한 사실 (2단계)
- 다운로드 출처: `kMDItemWhereFroms == "*google*"cd` 동작(이 맥 다운로드 폴더 74개 중 27개). 직접 스캔은 확장 속성 `com.apple.metadata:kMDItemWhereFroms`(바이너리 plist 문자열 배열)를 읽는다
- 태그: `kMDItemUserTags == "업무"cd`, 태그 있는 파일 전체는 `kMDItemUserTags == "*"`. `NSMetadataItemUserTagsKey` 상수는 Swift에 없어 문자열 `"kMDItemUserTags"`를 쓴다
- 제외 폴더는 `kMDItemPath`로 쿼리할 수 없어 결과 후처리. 걸러질 몫을 감안해 제외 규칙이 있으면 Spotlight 상한을 결과 상한의 5배로 받는다
- 창을 닫아도 앱이 살아 있어야 전역 단축키가 동작 → `applicationShouldTerminateAfterLastWindowClosed = false`, 닫힌 창은 SwiftUI `openWindow`를 보관해 두었다가 다시 연다
- 등록된 Carbon 단축키는 키 입력을 가로채므로, 설정에서 새 단축키를 기록하는 동안에는 잠시 해제한다
- `@AppStorage`는 문자열 배열을 못 다뤄 제외 폴더는 줄바꿈으로 이은 문자열로 저장
- Cursor 샌드박스 안에서 빌드하면 `@Observable` 매크로 플러그인 서버가 막혀 실패한다 → 빌드·테스트는 샌드박스 밖(all 권한)에서

### 2.3 불가능하거나 변경한 기능
- **"M5 가속 / M5 Neural Engine 분석"**: Spotlight 검색은 칩·Neural Engine과 무관 → 표현 제거.
- **"24GB RAM에 전체 디스크 메모리 캐시"**: 불가능하고 불필요 → 최근 검색 결과 캐시 정도만.
- **"Spotlight 점수 98% 일치"**: 관련도 점수(`kMDQueryResultContentRelevance`)는 **내용 검색일 때만** 의미 있음 → 내용 검색 시에만 표시.
- **"유사 파일 N개 발견"**: Spotlight 기능 아님 → 3단계의 중복 파일 찾기 / 비슷한 이미지 찾기(Vision, 실제 Neural Engine 사용)로 대체.
- **Spotlight 미색인 영역**: 숨김 파일, 패키지 내부, 시스템 폴더, Spotlight 제외 폴더, 미색인 외장·네트워크 드라이브 → `FileManager` 직접 스캔으로 보완(느림, 백그라운드·취소 가능).
- **내용 검색 한계**: HWP, 스캔 PDF·이미지 속 글자는 검색 안 될 수 있음 (UI에 안내 문구).

---

## 3. 참고 UI 분석 (`ref-assets/Chaja-Mac.html`)

HTML은 React 번들 시안이다. 아래 구성을 기준으로 하되 macOS 네이티브 관례에 맞게 다듬는다.

### 3.1 레이아웃 (3단)
1. **왼쪽 사이드바 (필터)** — 위에서 아래 순서
   - 검색창: placeholder "파일명 또는 내용", 지우기(x) 버튼
   - **확장자 칩**: `All`, `.pdf`, `.jpg/.png`(jpg, jpeg, png, heic, webp, ai, sketch), `.mov/.mp4`(mov, mp4, m4v, usdz), `.docx`(docx, doc, hwp, xlsx, numbers), `.swift/.js`(swift, js, ts, sh, log, py), `.zip`(zip, tar, gz) + "초기화"
   - **파일 종류 칩** (다중 선택, 색상 아이콘): 문서, 이미지, 동영상, 오디오, 코드, 압축, 폴더
   - **크기 범위**: 최소/최대(MB) 입력 + 프리셋 `~10MB`, `10~100MB`, `100MB+`
   - **수정일**: 전체 기간, 오늘, 최근 7일, 최근 30일, 1년, 직접 선택(시작~끝 날짜)
   - **옵션 토글**: 숨김 파일 포함(.파일 포함), 패키지 내용 검색(앱 내부까지), 대소문자 구분(정확히 일치)
   - **위치**: 전체 Mac, 홈 폴더, 데스크탑, 다운로드, 문서 (+ 네이티브에서는 "폴더 선택…" 추가)
   - **검색 버튼** + "평균 0.0X초 • N개 결과"
2. **가운데 결과 영역**
   - 툴바: "N개 항목", `"검색어" 검색 결과`, 선택된 종류 배지, 정렬(이름/크기/수정일), 리스트/그리드 전환, 미리보기 패널 토글
   - 리스트 컬럼: 이름(아이콘), 위치(`~` 축약), 크기, 수정일
   - 그리드: 아이콘 + 이름 + 크기 • 수정일
   - 빈 상태: "조건에 맞는 파일이 없어요" / "다른 키워드나 필터로 다시 시도해보세요. 숨김 파일 포함을 켜보는 건 어때요?" / "필터 초기화"
3. **오른쪽 미리보기(인스펙터)**
   - 큰 아이콘/썸네일, 파일명, 종류
   - 정보: 위치, 크기, 생성일, 수정일, 종류
   - 버튼: Finder에서 보기, 경로 복사, 열기
   - (시안의 "M5 Neural Engine 분석" 카드는 제거. 3단계 이후 "중복/비슷한 파일" 카드로 대체 가능)
4. **하단 상태바**: "Spotlight 인덱스 사용 중", "선택: 파일명" / "항목을 선택하세요"

### 3.2 네이티브에서 개선할 점
- 미리보기는 **Quick Look** 사용 (스페이스바 = Quick Look 패널, 인스펙터에 썸네일)
- 결과 행 **드래그 앤 드롭** (다른 앱/Finder로), **다중 선택**, 우클릭 컨텍스트 메뉴
- 키보드: ⌘F 검색창 포커스, Enter 검색, ⌘O 열기, ⌘R Finder에서 보기, ⌘⇧C 경로 복사, ⌘⌫ 휴지통
- 시스템 다크 모드 자동 대응

---

## 4. 아키텍처

### 4.1 기술 선택
- **SwiftUI** `NavigationSplitView`(사이드바 + 결과) + `.inspector`(미리보기)
- 결과 리스트: SwiftUI `Table` (대량 결과에서 느리면 `NSTableView` 래핑으로 교체)
- 검색: `NSMetadataQuery` (Spotlight) + `FileManager.enumerator` (직접 스캔), Swift Concurrency로 백그라운드 처리
- 미리보기: `QuickLookUI`(`QLPreviewPanel`), `QuickLookThumbnailing`(`QLThumbnailGenerator`)
- 파일 동작: `NSWorkspace`(열기, Finder에서 보기, 아이콘), `NSPasteboard`(경로 복사)
- 상태 관리: `@Observable` 모델
- 설정 저장: `UserDefaults` + 검색 저장은 JSON 파일(`~/Library/Application Support/Chaja/`)
- 프로젝트 생성: **XcodeGen** (`project.yml`이 원본, `.xcodeproj`는 생성물)
- 외부 의존성: 원칙적으로 없음. 전역 단축키는 Carbon `RegisterEventHotKey`로 직접 구현(손쉬운 사용 권한 불필요)

### 4.2 폴더 구조 (예정)
```
Chaja/
├── docs/handoff.md              # 이 문서
├── ref-assets/                  # 참고 시안·원본 아이콘 (수정 금지)
├── project.yml                  # XcodeGen 설정
├── Chaja.xcodeproj/             # xcodegen generate 로 생성
├── scripts/
│   ├── build-release.sh         # Release 빌드 + zip 생성
│   └── make-icon.sh             # chaja_icon.png → AppIcon 세트
└── Chaja/
    ├── App/            ChajaApp.swift (+AppDelegate, ChajaCommands)
    ├── Models/         SearchCriteria, FileItem, FileKind, DateFilter, ExtensionGroup, SearchScope, ExclusionRules, HotKey, AppSettings
    ├── Search/         SearchModel(조율·파일 동작), SpotlightSearchEngine, SpotlightQueryBuilder, FileSystemScanner, FileMatcher
    ├── Services/       PermissionService, IconProvider(+ThumbnailProvider), HotKeyService(+MainWindow, LaunchAtLogin), SearchLibrary(저장·최근 검색), FileMetadata(+FinderTag, TagCatalog)
    ├── Views/Settings/ SettingsView (일반: 단축키·로그인 실행·결과 상한·기본 위치 / 제외 폴더)
    ├── Analysis/       DuplicateFinder, SimilarImageFinder          # 3단계
    ├── Views/
    │   ├── ContentView.swift
    │   ├── Sidebar/    FilterSidebar, SearchField, ExtensionChips, KindChips, SizeRangeSection, DateSection, OptionsSection, LocationSection
    │   ├── Results/    ResultsTableView, ResultsGridView, ResultsToolbar, EmptyStateView
    │   ├── Inspector/  InspectorView
    │   ├── StatusBarView.swift
    │   └── Onboarding/ FullDiskAccessView
    └── Resources/      Assets.xcassets (AppIcon, 색상), Info.plist, Chaja.entitlements
```

### 4.3 검색 흐름
1. 사이드바 조작 → `SearchCriteria` 변경
2. `SearchCoordinator`가 300ms 디바운스 후 이전 검색 취소, 새 검색 시작 (버튼/Enter는 즉시 실행)
3. **Spotlight 엔진**: `SpotlightQueryBuilder`가 조건을 `NSCompoundPredicate(andPredicateWithSubpredicates:)`로 변환 → `NSMetadataQuery` 실행, `searchScopes` = 선택한 위치, 백그라운드 `operationQueue`에서 결과 수집
4. **직접 스캔 엔진**: "숨김 파일 포함" 또는 "패키지 내용 검색"이 켜진 경우에만 동시에 실행. `FileManager.enumerator`로 선택한 위치를 순회하며 같은 조건 적용 (`AsyncStream`으로 결과 전달, 취소 가능)
5. 두 결과를 경로 기준으로 **중복 제거·병합**, 제외 폴더 후처리 필터 적용
6. 결과를 배치(예: 200개 단위)로 UI에 반영, 표시 상한(기본 5,000개, 설정 가능) 초과 시 "더 보기" 및 "조건을 좁혀보세요" 안내
7. 상태바에 소요 시간, 결과 수, 사용 엔진 표시

### 4.4 조건 → Spotlight 속성 매핑

| 조건 | 속성 | 비고 |
|---|---|---|
| 이름 | `kMDItemFSName LIKE[cd] "*검색어*"` | 대소문자 구분 켜면 `[d]`만. `d`는 한글 자모(NFC/NFD) 차이 무시 |
| 내용 | `kMDItemTextContent LIKE[cd] "*검색어*"` | 검색 모드: "이름만 / 이름+내용" (기본: 이름만) |
| 확장자 | `kMDItemFSName LIKE[c] "*.pdf"` OR … | 칩 그룹 → 여러 확장자 OR |
| 종류 | `kMDItemContentTypeTree == "public.image"` 등 | 아래 표 참고 |
| 크기 | `kMDItemFSSize` BETWEEN | MB → 바이트 변환 |
| 수정일 | `kMDItemFSContentChangeDate >= 날짜` | |
| 생성일 | `kMDItemFSCreationDate` | 날짜 기준 선택: 수정일/생성일 |
| 다운로드 출처 (2단계) | `kMDItemWhereFroms == "*kakao*"cd` | |
| 태그 (2단계) | `kMDItemUserTags == "빨간색"cd` OR … | 여러 태그는 OR |
| 위치 | `NSMetadataQuery.searchScopes` | 전체 Mac = `NSMetadataQueryLocalComputerScope` |
| 제외 폴더 (2단계) | 쿼리 불가 → **결과 후처리**로 경로 접두어 제외 | |

종류 → UTType (구현 시 실제 파일로 검증할 것):

| 종류 | UTType |
|---|---|
| 문서 | `com.adobe.pdf`, `public.composite-content`, `public.text`(코드 제외), `com.apple.iwork.*`, `org.openxmlformats.*`, `com.microsoft.*`, hwp 확장자 |
| 이미지 | `public.image` |
| 동영상 | `public.movie` |
| 오디오 | `public.audio` |
| 코드 | `public.source-code`, `public.script`, `public.shell-script`, `public.json`, `public.xml` |
| 압축 | `public.archive`, `public.zip-archive` |
| 폴더 | `public.folder` (패키지 `com.apple.package` 제외) |

### 4.5 권한
- App Sandbox **끔** (`com.apple.security.app-sandbox` = false 또는 entitlements 미포함)
- 숨김 파일·보호 폴더 직접 스캔용 **전체 디스크 접근 권한**: 최초 실행 시 확인 → 없으면 안내 화면 + 설정 열기 버튼 (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)
- 권한은 맥마다 한 번씩 허용 필요. 자체 서명 인증서를 유지하면 업데이트 후에도 권한 유지됨

---

## 5. 상세 단계별 체크리스트

### 0단계 — 개발 환경 및 프로젝트 뼈대
- [x] 0-1. `git init`, `.gitignore` (`build/`, `DerivedData/`, `xcuserdata/`, `.DS_Store`, `Chaja.xcodeproj/` — 프로젝트 파일은 `project.yml`에서 생성하므로 커밋하지 않음)
- [x] 0-2. `brew install xcodegen` (2.46.0)
- [x] 0-3. `project.yml` 작성: 타깃 `Chaja`, macOS 26.0, Swift 6, 번들 ID `com.n22309002.Chaja`, 샌드박스 끔, arm64, Info.plist·entitlements는 XcodeGen이 생성
- [x] 0-4. `xcodegen generate` → Debug 빌드 성공, 빈 창(아이콘 + "Chaja" 제목) 실행 확인
- [x] 0-5. 앱 아이콘: `scripts/make-icon.sh` — 원본 1600px에서 (x 327, y 335, 944px 정사각형) 잘라 1024로 맞춘 뒤 16~1024 세트 생성. 원본 아이콘 교체 시 본체 위치가 다르면 스크립트의 CROP 값 수정
- [x] 0-6. 자체 서명 인증서 생성 — GUI 없이 CLI로 완료: OpenSSL로 코드 서명용 인증서 생성 → `openssl pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1` (OpenSSL 3 기본 형식은 `security import`가 못 읽음) → `security import … -T /usr/bin/codesign`
- [x] 0-7. `CODE_SIGN_IDENTITY: "Chaja Self-Signed"` 설정, Debug·Release 빌드 및 `codesign --verify --strict` 통과. 서명 요구사항 = `identifier "com.n22309002.Chaja" and certificate leaf = H"ecf48bc7…"`
- [x] 0-8. (추가) Hardened Runtime을 켜면 Debug 빌드가 `Chaja.debug.dylib` 로드 실패("different Team IDs")로 즉시 종료됨 → `ENABLE_HARDENED_RUNTIME: NO`로 해결

### 1단계 — 핵심 검색 앱
**모델** (`Chaja/Models/`)
- [x] 1-1. `FileItem` (url, 이름, 크기, 생성일, 수정일, 콘텐츠 유형, 종류 표시명, 폴더 여부, `FileKind`)
- [x] 1-2. `SearchCriteria` (검색어·대상(이름/이름+내용), 확장자 그룹+직접 입력, 종류, 크기, 날짜 프리셋·기준, 옵션 3종, 위치). `Codable`이라 2단계 검색 저장에 그대로 사용 가능
- [x] 1-3. `FileKind`, `ExtensionGroup`, `DatePreset`/`DateField`/`DateBounds`, `SearchScope`

**검색 엔진** (`Chaja/Search/`)
- [x] 1-4. `SpotlightQueryBuilder`: `SearchCriteria` → **Spotlight 쿼리 문자열**(`mdfind` 문법) → `NSPredicate(fromMetadataQueryString:)`. NSPredicate를 직접 만들지 않고 문자열을 쓰는 이유: `mdfind`로 똑같이 실행해 검증 가능
- [x] 1-5. `SpotlightSearchEngine`: `NSMetadataQuery`, 0.1초 배치, 상한(기본 1만 개) 도달 시 쿼리 중지, `valueListAttributes`로 속성 일괄 수신
- [x] 1-6. `FileSystemScanner`: `Task.detached` + `FileManager.enumerator`, 숨김/패키지 옵션, `FileMatcher`로 같은 조건 판정(본문 검색 제외), 취소 가능
- [x] 1-7. `SearchModel`(계획의 SearchCoordinator): 350ms 디바운스, 두 엔진 병합·경로 기준 중복 제거, 숨김 경로 후처리, 정렬(3,000개 이하는 배치마다, 그 이상은 완료 시 1회), 세대 번호로 이전 검색 결과 무시
- [x] 1-8. 한글 NFC/NFD: 실제 파일 두 개로 확인 — `cd`·`d` 수식어 모두 양쪽 다 검색됨. 직접 스캔은 `precomposedStringWithCanonicalMapping`으로 정규화 후 비교

**UI** (`Chaja/Views/`)
- [x] 1-9. `ContentView`: `NavigationSplitView` + `.inspector` + 하단 `StatusBar`, `.searchable(placement: .sidebar)`
- [x] 1-10. `FilterSidebar`: 이름/이름+내용 전환, 확장자 칩(+직접 입력), 종류 칩, 크기(입력+프리셋), 날짜(수정일/생성일 + 프리셋 + 직접 선택), 옵션 토글, 위치(+폴더 선택), 하단 찾기/중지 버튼·상태·필터 초기화
- [x] 1-11. `ResultsTable`(이름/위치/크기/수정일/종류, 열 정렬, 다중 선택) + `ResultsGrid`(썸네일) + 툴바(보기 전환, 정렬 메뉴, 미리보기 토글)
- [x] 1-12. 빈 상태(처음/검색 중/결과 없음) + 상한 초과 배너
- [x] 1-13. `InspectorView`: 단일 선택(썸네일, 정보, Finder에서 보기/열기/훑어보기/경로 복사), 다중 선택(개수·합계 크기)
- [x] 1-14. 스페이스바 훑어보기(`.quickLookPreview`), 행 드래그(`.draggable(url)`), 우클릭 메뉴 — **사용자 화면 확인 필요**
- [x] 1-15. 메뉴 단축키: ⌘F 검색창, ⌘↩ 지금 검색, ⌘O 열기, ⌘R Finder에서 보기, ⌘Y 훑어보기, ⌥⌘C 경로 복사, ⌘⌫ 휴지통(텍스트 입력 중엔 원래 동작 유지)
- [x] 1-16. 전체 디스크 접근 권한 확인(TCC.db 열기 시도) + 첫 실행 안내 시트 + 직접 스캔 옵션 켤 때 안내, 앱 활성화 시 재확인
- [x] 1-17. 리스트 아이콘은 콘텐츠 유형별 캐시(앱·패키지만 파일별), 썸네일은 보일 때만 생성 — **대량 결과 스크롤 체감은 사용자 확인 필요**

**1단계 검증 기준**
- [x] 앱 엔진 결과 수 = `mdfind -count` (통합 테스트 6개 케이스: 다운로드 전체, 홈 PDF, 문서+30일+10MB, 이미지 1MB+, 맥 전체 이름 '정산', 이름+내용 '정산')
- [x] 좁은 조건 첫 결과 1초 이내 (넓은 검색도 첫 결과 0.08초)
- [x] 넓은 검색(홈의 코드 파일 수십만 개): 1만 개 상한까지 1.5~1.7초 후 자동 중지 — 테스트로 5초 미만 보장
- [x] 숨김 파일·패키지 내부 직접 스캔 (`FileSystemScannerTests`)
- [x] 사용자 화면 확인 (UI 배치, 훑어보기, 드래그, 단축키) — 확인 중 받은 피드백 3건 수정:
  - **한글 입력 깨짐**("견적" → "견ㄱ"): SwiftUI `.searchable`이 조합 중 값을 되씀 → `Views/Sidebar/SearchField.swift`(NSSearchField 래핑)로 교체. 조합 중(`hasMarkedText`)에는 바인딩 갱신·값 덮어쓰기를 하지 않음. **검색창을 다시 SwiftUI 기본 컨트롤로 바꾸지 말 것**
  - 옵션 스위치 3개가 가운데 정렬 → 제목은 왼쪽, 스위치는 오른쪽 끝으로 배치
  - 사이드바 스크롤 내용이 검색창·하단 버튼 밑으로 겹쳐 보임 → `safeAreaInset` 대신 VStack 세 칸(검색창 / 스크롤 / 하단) + 구분선

**테스트**: `ChajaTests/` — Swift Testing 22개 (쿼리 빌더, 이름 매칭, 스캐너, Spotlight 통합·성능). `xcodebuild … test`로 실행. 개별 실행은 `-only-testing:'ChajaTests/스위트/함수()'`처럼 괄호 포함

### 2단계 — 편의 기능
- [x] 2-1. 전역 단축키 (기본 ⌃⌥F, 설정에서 변경·끄기) → Chaja 창 앞으로 + 검색창 포커스, 앞에 있으면 숨김. 창을 닫아도 앱 유지
- [x] 2-2. 설정 창 (`Settings` scene, ⌘,): 단축키 기록, 로그인 시 자동 실행(`SMAppService`), 결과 최대 개수, 기본 위치, 제외 폴더 탭
- [x] 2-3. 검색 조건 저장 (⌘S 또는 시계 메뉴 → 이름 입력 → 사이드바 상단 "저장된 검색", 우클릭으로 이름 변경·덮어쓰기·삭제, ‘검색’ 메뉴 ⌘1~9). `~/Library/Application Support/Chaja/searches.json`
- [x] 2-4. 최근 검색 10개 (Enter·찾기 버튼, 또는 결과를 열기·Finder 보기·경로 복사했을 때 기록. ‘견’→‘견적’처럼 이어 입력한 기록은 합침). 검색창 옆 시계 메뉴와 ‘검색’ 메뉴
- [x] 2-5. 제외 폴더 (기본값 `node_modules`, `.git`, `DerivedData`, `~/Library/Caches`; 이름은 어디서나, 경로는 그 위치만) 후처리 필터 + 직접 스캔 시 하위 진입 생략. 사이드바 옵션 "제외 폴더 적용"
- [x] 2-6. 다운로드 출처 필터 (`kMDItemWhereFroms`), 인스펙터에 출처 표시(링크 + 같은 사이트에서 받은 파일 찾기)
- [x] 2-7. Finder 태그 필터 (기본 색상 태그 + Spotlight로 찾은 사용 중 태그를 칩으로, 여러 개는 OR), 인스펙터에 태그 표시(눌러서 필터)
- [x] 2-8. 테스트 추가: 쿼리(출처·태그), 제외 규칙, 저장 형식 하위 호환, 검색 기록, 스캐너(제외·태그·출처), mdfind 비교 3건 → 전체 36개 통과
- [x] 2-9. 사용자 확인
- [x] 2-10. `README.md` 작성 (사용자 요청으로 4단계에서 앞당김. 기능·단축키·설치·빌드·구조·로드맵). 이후 단계마다 기능·로드맵·테스트 수 갱신

### 3단계 — 분석 기능
- [ ] 3-1. 중복 파일 찾기: 현재 결과 또는 선택 폴더 대상 → 크기로 그룹 → 앞부분 해시 → 전체 SHA-256(CryptoKit)으로 확정. 백그라운드·진행률·취소
- [ ] 3-2. 중복 결과 화면: 그룹별 표시, 원본 남기고 나머지 휴지통 이동(확인 대화상자 필수)
- [ ] 3-3. 비슷한 이미지 찾기: Vision `VNGenerateImageFeaturePrintRequest`로 특징값 생성 → 거리 비교 → 임계값 이하 묶기. 특징값 캐시(경로+수정일 키)
- [ ] 3-4. 인스펙터에 "중복 N개 / 비슷한 이미지 N개" 카드 (시안의 분석 카드 자리)

### 4단계 — 배포
- [ ] 4-1. `scripts/build-release.sh`: Release 빌드 → 자체 인증서 서명 → `codesign --verify` → `Chaja.zip` 생성 (`build/` 폴더)
- [ ] 4-2. 이 맥(M2)에서 `/Applications`에 설치 후 동작 확인
- [ ] 4-3. M5 맥에 AirDrop/USB로 복사 → 시스템 설정 > 개인정보 보호 및 보안 > "그래도 열기" → 전체 디스크 접근 권한 허용 → 동작 확인
- [ ] 4-4. `README.md`의 설치 절차를 실제 배포 결과에 맞게 보완 (업데이트 방법, 빌드 스크립트 사용법 추가)

---

## 6. 위험 요소 및 대응

| 위험 | 대응 |
|---|---|
| 넓은 검색에서 결과 수십만 개 → 느림/메모리 | 스트리밍 + 표시 상한 + 조건 좁히기 안내 |
| SwiftUI `Table`이 대량 행에서 느림 | `NSTableView` 래핑으로 교체 |
| 종류(UTType) 매핑이 실제 파일과 다름 | 1단계에서 실제 파일로 검증, 확장자 보조 매칭 |
| 직접 스캔이 오래 걸림 | 선택한 위치만 순회, 제외 폴더 생략, 진행률·취소 |
| 빌드 중 "codesign이 키체인 접근 허용" 암호 창이 반복해서 뜸 | CLI로 가져온 키는 접근 허용 목록(partition list)이 비어 있음. 사용자가 터미널에서 1회 실행해 해결함(2026-11-05): `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "Chaja Self-Signed" ~/Library/Keychains/login.keychain-db` (로그인 암호 입력). 인증서를 재생성하면 다시 실행 필요 |
| 키체인에서 `Chaja Self-Signed` 인증서가 삭제됨 | 0-6 절차로 재생성. 단, 인증서가 바뀌면 각 맥에서 전체 디스크 접근 권한을 다시 허용해야 함 |
| 앱 복사 후 Gatekeeper 차단 | "그래도 열기" 안내. 필요 시 `xattr -dr com.apple.quarantine /Applications/Chaja.app` |
| 에이전트 샌드박스에서 Spotlight·앱 실행 불가 | 해당 명령은 전체 권한으로 실행 |

---

## 7. 새 세션 시작 가이드
1. 이 문서 전체 읽기 → 5장 체크리스트에서 다음 할 일 확인
2. `ref-assets/Chaja-Mac.html`은 200KB 번들이라 통째로 읽지 말 것. 3장 요약을 우선 참고
3. 빌드 (전체 권한 셸에서):
   ```
   xcodegen generate
   xcodebuild -project Chaja.xcodeproj -scheme Chaja -configuration Debug -derivedDataPath build/DerivedData build
   open build/DerivedData/Build/Products/Debug/Chaja.app
   ```
   새 Swift 파일을 추가하면 `xcodegen generate`를 다시 실행해야 프로젝트에 포함된다
4. 응답은 항상 한국어로
5. **각 단계가 끝나면 사용자 확인을 받은 뒤 다음 단계로 진행** (사용자 요청)
   - 원격 저장소: https://github.com/tiper2066/chaja (브랜치 `main`). 단계 완료·확인 후 커밋하고 푸시
6. 작업 후 체크박스·1.3 단계 표·8장 작업 로그 갱신

---

## 8. 작업 로그

| 날짜 | 내용 |
|---|---|
| 2026-11-05 | 사전 검토 완료, 결정 사항 확정, 핸드오프 문서 작성 |
| 2026-11-05 | 0단계 완료: git, XcodeGen, `project.yml`, 아이콘, 자체 서명 인증서, Debug/Release 빌드·실행 확인. Hardened Runtime 끔 |
| 2026-11-05 | 1단계 구현: 모델·검색 엔진·UI 전체, 테스트 22개 통과. Swift 6.2 기본 MainActor 격리(`SWIFT_DEFAULT_ACTOR_ISOLATION`) 사용 — 백그라운드에서 쓰는 모델·검색 타입은 `nonisolated`로 표시. 키체인 암호 창 문제 해결, Spotlight 속성 일괄 수신으로 넓은 검색 20.3초 → 1.7초 |
| 2026-11-05 | 1단계 사용자 확인 완료(한글 입력·스위치 정렬·사이드바 겹침 수정). 커밋·푸시 후 2단계 시작 |
| 2026-11-05 | 2단계 구현(단축키·설정·저장/최근 검색·제외 폴더·출처·태그), 테스트 36개 통과 |
| 2026-11-05 | 2단계 사용자 확인 완료. README 작성 후 커밋·푸시. 다음은 3단계 |
