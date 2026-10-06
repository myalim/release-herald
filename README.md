# release-herald

Claude Code 세션을 시작할 때 새 릴리스의 주요 변경을 한국어로 알려 주는 플러그인입니다.
알림 내용은 Claude 의 컨텍스트에도 함께 전달되므로, 화면에 표시되지 않은 항목도 Claude 에게 질문할 수 있습니다.

```
[release-herald] Claude Code v2.1.288 → v2.1.289 (2개 버전) 주요 변경
  · 심링크를 거친 파일에 `Read` `deny` 규칙이 적용되지 않던 문제 수정
  · 샌드박스 자동 허용 시 변수 대입이 앞서면 Bash `deny`·`ask` 규칙이 건너뛰어지던 문제 수정
  · GitHub CLI 없는 클라우드 세션에 `gh api` 내장 및 터미널 제어문자 차단
```

## 설치

Claude Code 세션에서 다음 명령을 실행합니다.

```
/plugin marketplace add myalim/release-herald
/plugin install release-herald@release-herald
```

### 업데이트

자동 업데이트는 기본으로 꺼져 있습니다. 설치 후 `/plugin` → Marketplaces → release-herald → Enable auto-update 를 켜 두면 새 버전을 자동으로 받습니다.
켜지 않았다면 다음 명령으로 직접 받습니다. 받은 업데이트는 `/reload-plugins` 를 실행하거나 다음 세션부터 적용됩니다.

```
/plugin marketplace update release-herald
```

릴리스 요약은 플러그인과 따로 내려받으므로, 플러그인을 업데이트하지 않아도 새 릴리스 알림은 대개 그대로 표시됩니다.

### 요구 사항

| 항목 | 내용 |
| --- | --- |
| 운영체제 | macOS (Linux·WSL 미검증) |
| 도구 | `jq`, `curl` |
| API 키 · 설정 | 불필요 |
| 비용 | 없음 (사용자 환경에서 LLM 을 호출하지 않음) |

`jq` 가 없으면 알림 없이 종료됩니다. `brew install jq` 로 설치합니다.

## 동작 방식

- 세션 시작 시 아직 알리지 않은 릴리스의 주요 변경 표시
- 현재 실행 중인 버전까지만 알림
- 설치 후 첫 세션은 기준 버전만 기록하고 알림 생략
- 요약은 이 저장소의 GitHub Actions 가 3시간마다 공개 릴리스 노트를 바탕으로 생성
- 요약 파일은 최대 1시간에 한 번 내려받아 로컬에 캐시
- 네트워크 오류 등 어떤 실패도 세션 시작에 영향 없음
- 공개 릴리스 노트에 기재되지 않은 변경 사항은 대상 외

## 지난 릴리스 조회

| 명령 | 설명 |
| --- | --- |
| `/release-herald:show` | 릴리스 목록 (최신 10개, 이전 것은 범위로 조회) |
| `/release-herald:show 288` | 특정 릴리스의 변경 전체 (주요 변경과 그 밖의 변경) |
| `/release-herald:show 280..289` | 버전 범위 |
| `/release-herald:show --find 훅 출력` | 모든 낱말을 포함한 변경 (최신순) |
| `/release-herald:show --area hooks` | 특정 영역의 변경 (최신순) |

| 옵션 | 설명 |
| --- | --- |
| `--all` | 내부 변경 포함 |
| `--en` | 영문 원문 함께 표시 |

## 제거

```
/plugin marketplace remove release-herald
```

마켓플레이스를 제거하면 플러그인도 함께 제거됩니다. 로컬 캐시와 알림 기록은 다음 명령으로 삭제합니다.

```bash
rm -rf ~/.cache/release-herald ~/.local/state/release-herald
```

## 라이선스

[MIT](LICENSE)
