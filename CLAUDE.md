# release-herald

Claude Code 새 릴리스의 한국어 요약을 세션 시작 시 표시하고 Claude 컨텍스트에 주입하는 플러그인.

## 디렉터리 구성

| 경로 | 역할 |
| --- | --- |
| `hooks/` | 사용자 환경 실행 스크립트 — 세션 시작 알림(`session-start.sh`), 캐시 갱신(`update-cache.sh`), 조회(`show.sh`), 플러그인 훅 등록(`hooks.json`) |
| `scripts/` | CI 실행 스크립트 — 원문 추출·병합·검증(`build.py`), 판정(`classify-all.sh`, `area-all.sh`), 파이프라인 감시(`watch-pipeline.sh`) |
| `prompts/` | 판정 기준 — 화면 표시 여부(`classify.md`), 영역 분류(`area.md`) |
| `schema/` | 요약 데이터 형식(`summaries.schema.json`) |
| `data/summaries.json` | 생성된 요약 데이터 (CI 봇 커밋 전용, 직접 수정 금지) |
| `.github/workflows/` | 요약 갱신(3시간 주기), 릴리스 PR 생성 |
| `.claude-plugin/`, `skills/` | 플러그인·마켓플레이스 매니페스트, 조회 스킬 |

## 검증 명령

- 저장소 루트에서 실행
- 모든 테스트는 네트워크·판정 모델 없이 동작
- 셸 스크립트 수정 시 lint 와 관련 테스트 함께 실행
- 핵심 로직(원격 받기 · 상태 변경 · 데이터 변환) 변경 시 회귀 테스트 추가

| 명령 | 대상 |
| --- | --- |
| `./scripts/lint-workflows.sh` | 워크플로·셸 스크립트 (actionlint, shellcheck) |
| `./hooks/test-session-start.sh` | 세션 시작 알림 |
| `./hooks/test-update-cache.sh` | 캐시 갱신 |
| `./hooks/test-show.sh` | 조회 |
| `./scripts/test-validate.sh` | 데이터 형식 검증 |
| `./scripts/test-classify-all.sh` | 판정 |
| `./scripts/test-area-all.sh` | 영역 분류 |
| `./scripts/test-watch-pipeline.sh` | 파이프라인 감시 |

## 제약 사항

- 훅은 macOS 기본 bash 3.2 와 `jq` 만 사용 — 세션 시작 처리 시간 예산(100ms) 때문에 node·python 사용 금지
- bash 3.2 의 `set -u` 에서 빈 배열은 `${arr[@]+"${arr[@]}"}` 형태로 전개
- 훅의 모든 실패는 출력 없이 종료 — 생성 측 장애는 감시 job 이 이슈로 보고
- `summaries.json` 형식은 `schema/`, 최신순 정렬은 `build.py` 검증이 보장 — 훅은 버전 비교가 아닌 배열 위치로 알림 대상 판정
- 화면 표시 기준은 `prompts/classify.md` 소관 — 판정 오류는 데이터보다 기준을 먼저 수정

## 주석 규칙

- 코드만으로 의도가 드러나지 않는 분기·가드·실측 기반 값에 이유 기재
- 파일 상단에 목적 요약
- 자명한 코드에는 주석 생략
