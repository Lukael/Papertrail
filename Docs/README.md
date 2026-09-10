# 문서와 검증

현재 제품 동작은 [README](../README.md), [기술 명세](../TECHNICAL_SPEC.md),
[UI 설계](../DESIGN.md)를 기준으로 확인합니다. 날짜가 붙은 시나리오 결과는 해당 실행 시점의
검증 기록이며 이후 코드의 검증을 대신하지 않습니다.

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
