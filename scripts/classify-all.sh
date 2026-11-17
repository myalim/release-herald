#!/usr/bin/env bash
# 판정 루프 — 대기 중인 릴리스를 하나씩 판정기에 넘기고, 실패를 모아 마지막에 한 번 알린다.
#
# **워크플로의 `run:` 블록에서 빠져나온 코드다.** 거기 있을 때는 CI 왕복 말고는 돌려볼 방법이
# 없었다 — 17분짜리 실행 한 번이 유일한 검증이었다. 파일로 나오면 로컬에서 그대로 돌고,
# `CLASSIFY_CMD` 로 판정 호출만 갈아끼우면 사용량 없이 흐름만 볼 수도 있다.
#
# 워크플로에 남는 것은 배선(트리거·권한·`if`·`outputs`·시크릿)뿐이라 거의 안 바뀐다.
#
#   사용법: scripts/classify-all.sh [pending-dir] [judged-dir]
#   기본값: data/pending · data/judged
#
#   CLASSIFY_CMD  판정 호출을 갈아끼운다. 입력·출력 두 인자를 받는 명령이면 된다.
#                 안 주면 claude CLI 를 부른다.
#   CI_NOTE       판정 프롬프트 끝에 붙는 메모 (워크플로가 무인 실행임을 알리는 자리).
#
# 실패해도 루프를 멈추지 않는다 — 한 릴리스가 어긋났다고 이미 나온 판정까지 버리면 정체가
# 생기고, 원본 atom 이 최근 10개만 담아 그 사이 릴리스가 피드에서 빠지면 생성기가 되찾지 못한다.
# 대신 끝에서 1 로 끝낸다.

set -u

# 저장소 루트를 자기 위치에서 잡는다 — 어디서 부르든 같은 것을 읽게 한다. 상대 기본값이면
# 호출자의 cwd 에 따라 `rm -rf data/judged` 가 엉뚱한 곳을 가리키고 프롬프트도 못 읽는다.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/judge.sh
. "$ROOT/scripts/judge.sh"

PENDING_DIR="${1:-$ROOT/data/pending}"
JUDGED_DIR="${2:-$ROOT/data/judged}"

[ -d "$PENDING_DIR" ] || { echo "대기 디렉터리가 없습니다: $PENDING_DIR" >&2; exit 2; }

# 앞선 실행분이 남아 실패를 가리는 일이 없게 한다.
rm -rf "$JUDGED_DIR"
mkdir -p "$JUDGED_DIR"

# 판정 한 건. 갈아끼우는 자리가 여기 하나라 로컬 실행과 CI 실행이 같은 루프를 밟는다.
classify_one() {
  local in="$1" out="$2"
  if [ -n "${CLASSIFY_CMD:-}" ]; then
    $CLASSIFY_CMD "$in" "$out"
    return
  fi
  # 그 침묵(0 으로 끝나고 아무것도 안 씀)은 아래 출력 파일 검사가 잡는다. 호출 옵션의 이유는 judge.sh.
  judge_call "$ROOT/prompts/classify.md" "$in" "$out"
}

# 조각(`{버전}@{번호}`, build.py `_chunks`) 판정을 받는 자리 — 하위 디렉터리라 merge 가 읽는 `*.json` 에
# 섞이지 않는다.
PARTS="$JUDGED_DIR/parts"
mkdir -p "$PARTS"

# 판정 파일이 없으면 merge 가 그 릴리스만 거부하므로, 조각이 하나라도 실패한 릴리스는 잇지 않는다.
join_release() { # join_release <버전>
  local base="$1"
  case "$failed " in *" $base@"*) echo "::warning::$base — 실패한 조각이 있어 잇지 않는다"; return ;; esac
  jq -s '{releases: [.[0].releases[0] + {items: [.[].releases[0].items[]]}]}' "$PARTS/$base"@*.json \
    > "$JUDGED_DIR/$base.json" 2>/dev/null || {
    rm -f "$JUDGED_DIR/$base.json"
    echo "::warning::$base — 조각 판정을 잇지 못했다"
    failed="$failed $base"
  }
}

failed=''
found=0
for f in "$PENDING_DIR"/*.json; do
  # 매치가 없으면 glob 이 그대로 남는다 — 대기 0인 날 로컬에서 도는 경로다.
  [ -e "$f" ] || break
  found=$((found + 1))
  v=$(basename "$f" .json)
  case "$v" in *@*) out="$PARTS/$v.json" ;; *) out="$JUDGED_DIR/$v.json" ;; esac
  echo "::group::판정 $v"
  if classify_one "$f" "$out"; then
    # 판정기가 0 으로 끝나고도 아무것도 안 쓸 수 있다. 그 침묵을 여기서 끊는다.
    test -s "$out" || {
      echo "::warning::$v — 판정이 0 으로 끝났는데 출력 파일이 없다"
      failed="$failed $v"
    }
  else
    echo "::warning::$v — 판정이 실패로 끝났다"
    failed="$failed $v"
  fi
  echo "::endgroup::"
  # 마지막 조각을 마친 자리에서 바로 잇는다 — 루프 끝까지 미루면 단계 시간 제한에 걸렸을 때 다 판정한
  # 릴리스도 잇지 못하고 버려진다.
  case "$v" in
    *@*)
      last=$(printf '%s\n' "$PENDING_DIR/${v%@*}"@*.json | tail -1)
      [ "$f" = "$last" ] && join_release "${v%@*}"
      ;;
  esac
done

echo "판정 호출 $found (큰 릴리스는 조각마다 한 번)"

if [ -n "$failed" ]; then
  echo "::error::판정 실패:$failed"
  exit 1
fi
