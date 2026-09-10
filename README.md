# Papertrail

논문 PDF를 읽고 Codex와 대화한 뒤, 논문과 대화 내용을 종합한 문서를 만드는 macOS 앱입니다.
SwiftUI·SwiftData를 사용하며 macOS 14 이상에서 실행합니다.

## 사용 흐름

1. PDF를 가져와 논문을 읽고 채팅합니다. 업로드·선택·재실행만으로 문서를 생성하지 않습니다.
2. Review 패널의 **Generate document**를 누르면 논문 본문과 클릭 시점까지 완료된 해당 논문의 대화를 종합합니다. 채팅이 없으면 논문만 정리합니다.
3. 이후 대화를 반영하려면 **Regenerate document**를 누릅니다. 생성 중 추가한 메시지는 다음 생성에 포함됩니다.
4. 결과는 검증 후 별도 버전으로 보존됩니다. 재생성을 취소하거나 생성에 실패해도 기존 문서는 유지됩니다.

문서는 논문 근거와 대화의 질문·해석·가설·미해결 사항을 구분합니다. 모델은 검증 가능한 JSON을
출력하고 앱이 이를 HTML 문서로 표시합니다. 논문별 채팅은 지속 Codex 세션을 사용하며,
문서 생성은 매번 별도 세션에서 실행합니다.

왼쪽 논문 목록을 우클릭하면 이름을 수정할 수 있습니다. 채팅에는 날짜와 시간이 표시되며,
메시지 위에 마우스를 올리면 초와 시간대를 포함한 전체 일시를 확인할 수 있습니다.
PDF·Review 패널은 표시 여부와 너비를 조절할 수 있습니다.

채팅은 `$...$`, `\(...\)` 인라인 수식과 `$$...$$`, `\[...\]` 블록 수식을 표시합니다.
KaTeX가 앱에 포함되어 오프라인으로 렌더링하며, 코드 블록과 미완성 구문은 원문으로 남깁니다.
메시지를 우클릭해 **Copy message source**를 선택하면 LaTeX 구문을 포함한 원문을 복사합니다.

## 빌드 및 실행

Xcode가 `/Applications/Xcode.app`에 설치되어 있어야 합니다. Codex CLI 설치 및 로그인도 필요합니다.

```sh
Scripts/build-gate0h-app.sh
open Papertrail.app
```

스크립트는 Xcode의 SwiftData 툴체인으로 release 앱을 빌드하고 ad-hoc 서명을 검증합니다.
실행 파일은 프로젝트 루트의 `Papertrail.app`입니다.
앱 데이터는 `~/Library/Application Support/Papertrail`에 저장됩니다.

## 문서 및 검증

- [기술 명세](TECHNICAL_SPEC.md): 저장 모델, 생성 입력·검증, Codex 연동 경계
- [UI 설계](DESIGN.md): 화면 구성과 상호작용
- [검증 안내](Docs/README.md): 테스트 실행 방법과 산출물 관리
- [최근 시나리오 결과](Docs/Scenarios/2026-09-10-manual-document-scenarios.md): 실제 앱·Codex 검증 및 한계

## 릴리스 브랜치

Git Flow 기준으로 `main`은 배포 이력, `develop`은 다음 개발 기준으로 사용합니다.
긴급 수정은 배포 태그에서 `hotfix/<version>` 브랜치를 만들고, 검증 후 `main`과
`develop`에 merge commit으로 반영합니다. 배포 태그 `v<version>`은 `main`의 해당
릴리스 커밋에 생성하고 GitHub Release에 앱 ZIP과 SHA-256 체크섬을 첨부합니다.
