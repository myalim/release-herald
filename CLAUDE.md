## 초기 설정

1. `cp CLAUDE.md.example CLAUDE.md`
   - 아래 Tech Stack, Package Manager를 프로젝트에 맞게 수정
2. `cp .mcp.json.example .mcp.json` 후 API 키 등 입력
3. `.claude/settings.local.json` 설정
   - Claude Code 실행 시 자동 생성되므로 별도 작업 불필요
   - 커스텀 설정이 필요한 경우 아래 두 가지 방법 중 선택:
     - **방법 1**: Claude Code 실행 후 자동 생성된 파일을 직접 수정
     - **방법 2**: example 파일을 복사하여 수정

       ```bash
       cp .claude/settings.local.json.example .claude/settings.local.json
       ```

- 설정 가능한 항목은 `.claude/settings.local.json.example` 참고

## 코드 탐색 규칙 (필수)

코드 파일(.ts, .tsx, .js, .jsx 등) 탐색 시 **Serena MCP 심볼 도구를 반드시 우선 사용**한다.
텍스트·파일 검색(Glob/Grep, 네이티브 빌드는 Bash `bfs`/`ugrep`)이나 파일 통째 Read 를
코드 탐색의 첫 수단으로 쓰지 않는다.

상세 절차(overview → 시그니처 → body)·도구 선택 기준·빌드별 Fallback 은
`.claude/rules/serena-exploration.md` 를 따른다.

예외: .md, .json, .yml 등 Serena 미지원 파일만 직접 검색·Read 허용.

## Package Manager

<!-- 프로젝트에 맞게 수정 -->

사용 가능한 명령은 @package.json을 참조

## Tech Stack

<!-- 프로젝트에 맞게 수정 -->

| Category  | Technology |
| --------- | ---------- |
| Framework |            |
| Language  |            |
| Styling   |            |

## Naming Conventions

`@docs/coding-conventions.md` 참고

## Git 브랜치 규칙

첫 번째 Edit 또는 Write 실행 전, 반드시 `git branch --show-current`로 현재 브랜치를 확인한다.

### main 브랜치 감지 시 필수 절차

> **예외:** `.gitignore` 대상 파일/디렉토리는 main 브랜치에서도 Edit/Write 허용

1. Edit/Write 실행을 **즉시 중단**한다
2. 사용자에게 현재 main 브랜치임을 알린다
3. 기능 단위로 브랜치 이름을 제안한다
   - 형식: `feature/{기능-요약}`
4. 사용자 승인 후 브랜치를 생성한다 (`git switch -c`)
5. 브랜치 전환 완료 후에만 Edit/Write를 실행한다

**main 브랜치에서 Edit/Write 실행 절대 금지**

## 금지 규칙

### 파일 조작

- 사용자 승인 전 Write, Edit, mkdir, rm 실행 절대 금지
- Plan mode에서 코드 작성 절대 금지 (계획만)
- 승인 없이 새 패키지 설치 절대 금지

### Git

- 승인 없이 git add, git commit, git reset 실행 절대 금지
- 커밋은 반드시 `/git-commit`으로 위임
- Co-Authored-By, Signed-off-by 등 모든 서명/trailer 추가 절대 금지 — git commit 시 `--trailer`, `--signoff`, `-s` 옵션 사용 금지

## Plan Mode 완료 체크리스트

ExitPlanMode 실행 전 반드시 확인:

- [ ] 누락된 단계가 없는가?
- [ ] 중복 작업이 없는가?
- [ ] 불필요한 오버헤드(파일, 추상화, 설정)가 없는가?
- [ ] 영향받는 파일 목록이 명시되어 있는가?
- [ ] 기존 코드 패턴과 일관성이 있는가?
- [ ] 전제 조건/가정이 명시되어 있는가?

## 반복 패턴 감지

> 스킬 실행 중에는 적용하지 않는다 (일반 대화에서만 감지).

### 트리거 조건

다음 중 하나가 세션 내에서 **2회 이상** 발생하면 감지:

- **교정 반복**: 사용자가 Claude 출력을 같은 방식으로 교정 (예: 네이밍 컨벤션, import 순서, 코드 스타일)
- **동일 작업 반복 요청**: 자동화 가능한 같은 종류의 작업을 반복 요청 (예: "타입 추가해줘", "에러 핸들링 빠졌어")
- **같은 실수 반복**: Claude가 같은 유형의 실수를 반복 (예: 같은 lint 규칙 위반, 같은 패턴의 타입 에러)

### 감지 시 행동

1. 패턴을 사용자에게 보고
2. CLAUDE.md 규칙 추가 또는 `.local/BACKLOG.md` 기록을 제안
3. 사용자 승인 후 반영

Plan mode에서는 보고만 하고 파일 수정은 종료 후로 미룬다.

## 주석 규칙

중요한 로직이나 복잡한 변경에는 항상 주석을 작성한다.
다른 개발자도 코드를 이해할 수 있도록, 의도와 맥락이 드러나는 주석을 작성한다.

- 새로운 로직 추가, 비직관적인 분기, 가드 패턴 등 "왜 이렇게 했는지"가 코드만으로 명확하지 않은 곳에 주석을 작성
- 파일 상단에는 전체 목적 요약, 핵심 라인에는 인라인 주석
- 단순하고 자명한 코드에는 불필요한 주석을 달지 않는다

## 문서 동기화 규칙

<!-- 프로젝트에 맞게 경로를 수정 (예: docs/analysis/, docs/policy/, docs/spec/) -->

코드 수정 시 관련 분석 문서(`docs/analysis/`, `docs/policy/`, `docs/spec/` 등)를 반드시 확인하고 동기화한다.

1. 문서가 있으면 → 변경 사실 + 발견 경위를 포함하여 동기화. **갱신 여부를 묻지 말고 기본 동작으로 수행**하되, 어떤 문서를 어떻게 고쳤는지 보고한다 (README 흐름도·옵션표·정책 섹션 등 동작 설명 문서 포함)
2. 문서가 없고 의사결정이 수반된 변경이면 → 문서 생성 필요 여부를 사용자에게 제안
3. 단순 수정이면 → 문서 불필요

문서 갱신 시 결과뿐 아니라 발견 경위(어떤 에러로 발견, 어떤 검토 중 확인 등)를 함께 기록한다.
코드 수정 완료 후, 커밋 전에 관련 분석 문서 존재 여부를 확인한다. 동작이 바뀌었는데 문서가 옛 동작을 설명하면 변경 의도가 코드에만 남아 추적이 어려워진다.

## 검증 규칙

코드 변경 후 아래 순서로 실행, 실패 시 자동 수정 금지하고 보고:

1. typecheck
2. lint
3. build (필요 시)

## 테스트 규칙

- 핵심 로직(API 호출, 상태 변경, 데이터 변환)은 테스트 작성
- UI 단순 렌더링은 테스트 생략
