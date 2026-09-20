#!/usr/bin/env bash
# 셸·워크플로 검사 — YAML 문법·표현식과 셸 스크립트를 로컬에서 본다.
#
# **이 자리가 없어서 문법 검증을 CI 로 미뤘다** — 로컬에 YAML 파서가 없으면 워크플로의
# 오타를 17분짜리 실행 한 번으로만 알 수 있다. actionlint 는 파싱에 더해 `${{ }}` 표현식과
# `run:` 안의 셸까지 본다(shellcheck 이 있으면 함께 쓴다).
#
#   사용법: ./scripts/lint-workflows.sh
#   설치:   brew install actionlint

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v actionlint >/dev/null 2>&1; then
  echo "actionlint 가 없습니다 — brew install actionlint" >&2
  exit 2
fi

ROOT="$(cd "$HERE/.." && pwd)"
rc=0

# `.yaml` 도 함께 본다 — 확장자 하나만 걸면 새 워크플로가 조용히 검사 밖에 남는다.
find "$ROOT/.github/workflows" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null \
  | xargs -0 -r actionlint || rc=1

# **셸 스크립트를 따로 건다** — actionlint 는 워크플로 `run:` 블록 안의 셸만 shellcheck 에
# 넘긴다. 그 블록을 파일로 빼면 검사도 함께 빠져나가므로, 여기서 다시 덮는다.
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$ROOT/scripts/"*.sh "$ROOT/hooks/"*.sh || rc=1
else
  echo "shellcheck 이 없어 셸 스크립트는 건너뜁니다 — brew install shellcheck" >&2
fi

exit "$rc"
