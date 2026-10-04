# 영역 기준 — `area`

> **이 파일이 영역 판정 기준의 SSOT 다.** 영역의 형식(목록·개수)은 `schema/summaries.schema.json` 이 강제한다.
> `impact`·`weight`·`ko` 판정(`prompts/classify.md`)과 **호출을 나눈다** — 한 프롬프트에 함께 두었더니 영역 표가
> `impact` 판정에 섞여 다른 항목의 `impact`·`weight` 가 뒤집혔다. 다시 합치지 않는다 — 이 판정은 영역만 낸다.

## 할 일

1. **지시받은 입력 파일**을 읽는다 — 릴리스 하나의 원문 항목(`en`)이 들어 있다.
2. 항목마다 영역을 정해 **지시받은 출력 파일**에 아래 형태로 쓴다. **`Write` 는 한 번만** 한다.
   - `areas` 의 길이는 입력 `items` 의 길이와 같고, **순서도 같다** — n번째 배열이 n번째 항목의 영역이다.
3. **그 밖의 일은 하지 않는다** — 이 파일과 입력 파일 외에는 아무것도 읽지 않고, 다른 파일을 고치지 않는다.

```jsonc
// 입력
{ "version": "v2.1.267", "items": [ { "en": "Fixed …" }, { "en": "Fixed …" } ] }

// 출력 — 영역만. 항목 순서 그대로, 항목마다 원소 하나짜리 배열
{ "version": "v2.1.267", "areas": [ ["permissions"], ["sessions"] ] }
```

`items` 가 빈 릴리스는 `"areas": []` 로 낸다.

## 판정

**판정 질문은 하나다 — "이 변경은 Claude Code 의 어느 표면에서 일어났나."** 값은 아래 목록에서 **하나만**
고른다. 두 표면에 걸쳐 보여도 변경이 일어난 쪽 하나다 — 아래 경계가 어느 쪽인지 정한다.
- **보안은 영역이 아니다** — 그 몫은 `weight 1` 이 갖는다. 비밀 노출·우회·경로 탈출은 **그것이 일어난 표면**으로 간다.
- 어디에도 안 맞으면 `other` 다 — "버그 수정 및 안정성 개선" 같은 무내용 항목, `/feedback`·`/bug` 류.

| 영역 | 표면 |
| --- | --- |
| `permissions` | 도구 호출 허용 여부 — 허용·거부·확인 규칙 · 권한 모드(auto·bypass·plan·acceptEdits) · 권한 프롬프트 · 작업 디렉터리 신뢰 |
| `sandbox` | Bash 샌드박스의 OS 수준 격리 — 파일·네트워크 경계 · 허용 도메인 · auto-allow |
| `hooks` | 훅 이벤트·매처·실행 · `/hooks` |
| `settings` | 설정 파일의 로드·우선순위·managed settings·환경변수·`/config` 메커니즘 |
| `auth-account` | Claude(Anthropic) 계정의 로그인·구독·조직 정책·API 키 — GitHub 등 외부 계정·토큰 연결은 그것을 쓰는 기능의 영역 |
| `mcp` | MCP 서버·커넥터 연결·OAuth·도구 노출 |
| `plugins` | 플러그인·마켓플레이스·LSP·플러그인 모니터 |
| `skills-commands` | 스킬·커스텀 슬래시 커맨드와 그 frontmatter |
| `agents` | subagent·에이전트 팀·agent view·Workflow·SendMessage · 에이전트 정의 frontmatter |
| `memory-context` | CLAUDE.md·rules·auto-memory·output style·system prompt |
| `models-usage` | 모델·effort·fast·thinking·사용량 한도·프롬프트 캐시·`/cost` |
| `sessions` | 로컬 세션 수명 주기 — resume·compact·transcript·백그라운드·worktree · `-p`·SDK 실행 |
| `tools` | 내장 도구 — Bash·Read·Edit·WebFetch·PDF·AskUserQuestion·Monitor |
| `terminal-ui` | 터미널 렌더링·입력·단축키·vim·전체화면·스크린리더 |
| `runtime` | 설치·업데이트·OS·네트워크·프록시·재시도·API 오류 |
| `remote-control` | 로컬 세션을 앱·웹·폰에서 조종하는 Remote Control |
| `cloud-sessions` | Anthropic 이 호스팅하는 세션 — 웹·routine·teleport·Cowork |
| `ide-desktop` | VS Code·JetBrains·Desktop 앱·Claude in Chrome·모바일 앱 자체 |
| `claude-tag` | Slack 의 Claude (Claude Tag) |
| `artifacts` | Artifact 게시·감시·`/artifacts` |
| `code-review` | GitHub Code Review·`/code-review`·`/ultrareview`·GitHub App |
| `providers` | Bedrock·Vertex·Foundry·게이트웨이 등 3P 프로바이더 연동 |
| `other` | 위 어디에도 안 맞음 |

원문의 대괄호 접두어(`[VSCode]`·`[Claude Tag]`·`[Code Review]`·`[Cloud sessions]`·`[Claude Code on the web]`)는
그 영역을 그대로 준다. 나머지는 아래 경계로 가른다 — **판정이 어긋난 곳이 전부 이 경계였다.**

- **`permissions` ↔ `sandbox`** — 도구 호출을 허용할지 판정하면 `permissions`, OS 수준 격리면 `sandbox`.
- **`permissions` ↔ `hooks`** — 훅이 판정 주체면 `hooks` ("매칭 실패 시 PreToolUse 훅이 건너뛰어짐" → `hooks`).
- **`permissions` ↔ `settings`** — 규칙·모드의 **의미**면 `permissions`, 설정 파일을 **읽는 방식**(로드·우선순위·managed)이면 `settings`.
    읽는 방식의 결함이면 그 키가 특정 기능의 것이어도 `settings` 다 ("managed `allowedHttpHookUrls`… 를 못 읽으면 전부 허용" → `settings`).
- **`permissions` 가 아닌 것** — OS 권한 거부(파일 시스템·macOS 권한)·조직 권한·데이터 공유 동의 프롬프트는
  도구 호출 허용과 무관하다. 일어난 표면으로 보낸다(`runtime`·`auth-account` 등).
- **권한 ↔ 호스트·기능 표면** — 어떤 호출이 허용·거부되나(규칙·모드·분류기의 판정)가 바뀌면 그 판정이 특정 기능의
  호출에 한정돼도 `permissions` 다 ("auto 모드에서 Workflow `agent()` 호출이 분류기 검사 없이 거부됨" → `permissions`).
  허용은 그대로인데 Remote Control·Chrome·클라우드가 프롬프트나 모드를 표시·전달하지 못한 것이면 그 호스트 영역이다.
- **`sessions` ↔ `remote-control` ↔ `cloud-sessions`** — 로컬 수명 주기 · 로컬 세션을 원격에서 조종 · Anthropic 호스팅.
  모바일·웹 클라이언트에서 보이는 결함도 이 셋으로 가른다 — 로컬 세션을 조종하는 화면이면 `remote-control`,
  호스팅 세션이면 `cloud-sessions`, 앱 자체(설치·알림·앱 고유 화면)면 `ide-desktop`.
- **결과 ↔ 원인** — 프롬프트 캐시 미스·thinking 누락·사용량 증가는 결과라 영역이 아니다. 그 결과를 낸 표면(재개면
  `sessions`, 커넥터 재연결이면 `mcp`, fork 면 `agents`)이 영역이다. 캐시·thinking·모델 전환 동작 자체를 고친 것만
  `models-usage` 다.
- **`mcp` ↔ `plugins`** — 연결·도구 노출이면 `mcp`, 설치·검증이면 `plugins`.
- **`terminal-ui` ↔ 기능 화면** — 특정 기능의 화면(`/plugin`·`/skills`·`/mcp`·`/workflows`·`/permissions` 같은 그 기능의
  목록·대화상자)의 배치·문구·키 입력은 **그 기능**이다. `terminal-ui` 는 어느 기능에도 매이지 않은 터미널 전체의
  렌더링·입력·단축키·스크롤·스크린리더다.
- **`models-usage` ↔ `runtime`** — 재시도·연결·프록시는 `runtime`.
- **`auth-account` ↔ `providers`** — claude.ai·Console 로그인과 조직 정책이면 `auth-account`, 3P 프로바이더·게이트웨이 설정이면 `providers`.
