#!/usr/bin/env bash
# 워크플로 검사 — YAML 문법·표현식·셸 스크립트를 로컬에서 본다.
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

actionlint "$HERE/../.github/workflows/"*.yml
