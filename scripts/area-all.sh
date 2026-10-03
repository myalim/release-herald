#!/usr/bin/env bash
# 영역 판정 루프 — 영역이 없는 릴리스마다 영역만 묻고, 결과를 영역 디렉터리에 둔다.
#
# 입력은 `build.py area-pending` 이 원문(`en`)만 담아 만든다 — 판정기가 `impact`·`weight`·`ko` 를 보지
# 못하므로 영역 판정이 그 값에 섞일 길이 없다(한 프롬프트에 합쳤을 때 섞였다). 받은 영역을 붙이고
# 검증하고 못 붙인 것을 알리는 일은 `build.py attach-area` 한 곳이 한다.
#
#   사용법: scripts/area-all.sh [pending-dir] [areas-dir]
#   기본값: data/area-pending · data/areas
#
#   AREA_CMD  판정 호출을 갈아끼운다. 입력·출력 두 인자를 받는 명령이면 된다.
#             안 주면 claude CLI 를 부른다.
#   CI_NOTE   판정 프롬프트 끝에 붙는 메모 (무인 실행임을 알리는 자리).
#
# 판정이 실패해도 루프를 멈추지 않고 종료 코드도 0 이다 — 영역 파일이 없는 릴리스는 attach-area 가
# "영역 미부착" 으로 알리고, 영역이 없는 채로 남아 다음 실행에서 다시 대상이 된다.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/judge.sh
. "$ROOT/scripts/judge.sh"
PENDING_DIR="${1:-$ROOT/data/area-pending}"
AREAS_DIR="${2:-$ROOT/data/areas}"

[ -d "$PENDING_DIR" ] || { echo "영역 판정 대기 디렉터리가 없습니다: $PENDING_DIR" >&2; exit 2; }

# 앞선 실행분이 남아 다른 회차의 영역이 붙는 일이 없게 한다.
rm -rf "$AREAS_DIR"
mkdir -p "$AREAS_DIR"

# 판정 한 건. 갈아끼우는 자리가 여기 하나라 로컬 실행과 CI 실행이 같은 루프를 밟는다.
area_one() {
  if [ -n "${AREA_CMD:-}" ]; then
    $AREA_CMD "$1" "$2"
    return
  fi
  judge_call "$ROOT/prompts/area.md" "$1" "$2"
}

found=0
for f in "$PENDING_DIR"/*.json; do
  # 매치가 없으면 glob 이 그대로 남는다 — 영역 없는 릴리스가 없는 회차다.
  [ -e "$f" ] || break
  found=$((found + 1))
  v=$(basename "$f" .json)
  echo "::group::영역 $v"
  area_one "$f" "$AREAS_DIR/$v.json" || echo "::warning::$v — 영역 판정이 실패로 끝났다"
  echo "::endgroup::"
done

echo "영역을 물은 릴리스 $found"
