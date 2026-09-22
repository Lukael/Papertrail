# 문서와 검증

현재 제품 동작은 [README](../README.md), [기술 명세](../TECHNICAL_SPEC.md),
[UI 설계](../DESIGN.md)를 기준으로 확인합니다. 날짜가 붙은 시나리오 결과는 해당 실행 시점의
검증 기록이며 이후 코드의 검증을 대신하지 않습니다.

## 최신 릴리즈

[v1.2.0 릴리즈 노트](Releases/v1.2.0.md)에 PDF 검색·채팅 줄바꿈·다크 모드 수정과 검증 범위를 정리합니다.
질문 미리보기와 클릭 영역 수정은 [v1.1.2](Releases/v1.1.2.md)를 참고합니다.
채팅 읽기 화면 개선은 [v1.1.1](Releases/v1.1.1.md)을 참고합니다.
이전 기능 릴리즈는 [v1.1.0](Releases/v1.1.0.md)을 참고합니다.
로컬 검증 로그는 `.build/scenarios/release-1.2.0`에 보관합니다.

## 회귀 테스트

테스트는 XCTest 타깃이 아닌 Swift 실행 파일로 구성되어 있습니다. 아래 명령은
Command Line Tools의 portable 저장소를 사용하는 결정적 테스트를 순서대로 실행합니다.
실제 앱은 Xcode로 빌드한 SwiftData 저장소를 사용합니다.

```sh
for target in Gate0ATests Gate0CTests Gate0DTests Gate0ETests Gate0FTests Gate0GTests Gate0HTests ChatMathTests; do
  DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run "$target" || exit 1
done
```

2026-09-10 수동 문서 생성 시나리오에서는 D/E/F/G/H 총 91개 그룹을 통과했습니다.
A/C는 이 91개 집계에 포함되지 않습니다.

## WebKit 메시지 스크롤 회귀 검사

macOS 로그인 세션에서 아래 명령으로 실제 WebKit의 메시지 내부 스크롤을 검사합니다.
WebKit 보조 프로세스를 실행해야 하므로 제한된 샌드박스에서는 실행되지 않을 수 있습니다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run --disable-sandbox ChatMathTests --web-scroll
```

트랙패드 회귀 검사는 전체 제스처 1,000회와 실제 SwiftUI 채팅 View의 관성 이동을 검사합니다.
일반 채팅 60개와 수식 포함 채팅 20개를 별도 창에 표시하며 사용자 앱에 입력을 보내지 않습니다.
로그는 `.build/scenarios/scroll-render`에 저장합니다. 합성 이벤트 검사이므로 물리 트랙패드의
WindowServer 전달 경로와 실제 프레임 속도 측정을 대신하지 않습니다.

```sh
python3 Scripts/verify-chat-scroll.py
```

## 논문 정렬과 긴 대화 전환

`verify-chat-scroll.py`는 최근 40개 표시 범위와 과거 질문 확장 검사를 포함합니다.
400개 메시지의 전체 렌더 방식과 현재 방식을 별도 네이티브 창에서 비교해
수식 WebView 수와 초기 레이아웃 시간을 `.build/scenarios/scroll-render`에 기록합니다.

```sh
swiftc -parse-as-library Sources/PapertrailApp/PaperListSorting.swift Tests/PaperListSortingTests.swift -o .build/PaperListSortingTests
.build/PaperListSortingTests
python3 Scripts/verify-chat-store-query.py
```

SwiftData 조회 검사는 메모리 저장소의 다른 논문 메시지 2,000개와 대상 메시지를 섞어
백그라운드 조회의 논문 격리·동일 시각 정렬·빈 기록을 확인합니다. 실제 사용자 저장소는
열지 않습니다. 전체 Xcode가 필요합니다.

## 논문 검색과 태그

제목 검색과 정렬의 결합은 `PaperListSortingTests`에서 검사합니다. 태그 저장소 검사는
임시 라이브러리만 사용하며 실제 사용자 태그를 변경하지 않습니다.

```sh
mkdir -p .build/scenarios/paper-search-tags
swiftc -module-cache-path .build/ModuleCache -parse-as-library -D PPR_PORTABLE_SCHEMA \
  Sources/PapertrailCore/Storage/LibraryPaths.swift Sources/PapertrailCore/Storage/PaperTagStore.swift \
  Tests/PaperTagStoreTests.swift -o .build/scenarios/paper-search-tags/PaperTagStoreTests
.build/scenarios/paper-search-tags/PaperTagStoreTests
```

태그 편집창의 키보드 입력·추가·저장 검사는 격리된 네이티브 창에서 실행합니다.
현재 자동화 환경에서 SwiftUI 버튼의 접근성 클릭과 전체 비트맵 렌더링은 지원되지 않아,
삭제·취소 버튼 클릭 및 전체 외관은 이 검사에서 보장하지 않습니다.

```sh
swiftc -module-cache-path .build/ModuleCache -parse-as-library \
  Sources/PapertrailApp/PaperListSorting.swift Sources/PapertrailApp/PaperTagsEditor.swift \
  Tests/PaperTagsEditorTests.swift -o .build/scenarios/paper-search-tags/PaperTagsEditorTests
.build/scenarios/paper-search-tags/PaperTagsEditorTests
```

## PDF 검색과 채팅 줄바꿈

```sh
sh Scripts/verify-pdf-search.sh
python3 Scripts/verify-chat-scroll.py --layout-only
```

PDF 검사는 생성한 임시 PDF에서 대소문자 무시 검색·페이지 간 결과 이동·검색 해제·문서 전환을 확인합니다.
채팅 검사는 실제 입력창 코드에 Shift+Enter를 보내 커서 위치 줄바꿈과 전송 방지를 확인하고, Enter가 한 번 전송되는지 검사합니다. 실제 Codex에는 요청하지 않습니다.

## 실제 Codex 생성

다음 하네스는 별도 라이브러리에 합성 논문과 완료된 대화를 넣고 실제 Codex를 호출합니다.
Codex CLI 로그인과 네트워크 연결이 필요하며 모델 사용량이 발생합니다.
매 실행마다 새 결과 디렉터리를 사용합니다.

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift run Gate0FHarness \
  "$PWD" "$PWD/.build/scenarios/synthesis-$(date +%Y%m%dT%H%M%S)" \
  "$(command -v codex)" 300 --with-conversation
```

앱 UI 검증은 다음처럼 사용자 데이터와 분리된 경로로 실행할 수 있습니다.

```sh
open -na "$PWD/Papertrail.app" --args \
  --papertrail-application-support "$PWD/.build/scenarios/ui-library"
```

## 검증 기록과 산출물

- [채팅 LaTeX 검증](Scenarios/2026-09-10-chat-math.md)

- [최신 시나리오 보고서](Scenarios/2026-09-10-manual-document-scenarios.md)
- [회귀 테스트 요약](Scenarios/2026-09-10-manual-document-regression.json)
- [UI 데이터 검증](Scenarios/2026-09-10-manual-document-ui-evidence.json)
- [실제 Codex 생성 증거](Scenarios/2026-09-10-paper-chat-synthesis-evidence.json)

`Scenarios`에는 보고서와 작은 증거 요약만 보관합니다. `.build/scenarios`에는 로컬 실행의
입력·로그·생성 문서가 있으며 Git에서 제외합니다. 증거 요약의 절대 경로는 해당 로컬 실행
위치를 나타내므로 다른 환경에 파일이 없을 수 있습니다.

기존 `Scripts/verify-gate0*.sh`는 단계별 개발 검증 도구입니다. 일부는 실제 Codex 호출,
WebKit UI 실행, Command Line Tools 환경에서 SwiftData 빌드가 실패하는 조건 검사를
포함합니다. 전체 스크립트를 일반 단위 테스트로 취급하지 않습니다. 이 스크립트들이 만드는
`Docs/Gate*/evidence`는 재생성 가능한 임시 출력이며 Git에서 제외합니다.

오래된 Gate 로그·실행 데이터·중복 앱 번들과 과거 수정 경과 문서는 정리했습니다.
현재 루트 앱, 소스·테스트·fixture·스크립트 및 최근 시나리오의 원시 증거는 유지합니다.
