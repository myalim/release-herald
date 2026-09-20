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
# 생기고, 원본 atom 이 9일 창이라 그 사이 릴리스가 사라진다. 대신 끝에서 1 로 끝낸다.

set -u

# 저장소 루트를 자기 위치에서 잡는다 — 어디서 부르든 같은 것을 읽게 한다. 상대 기본값이면
# 호출자의 cwd 에 따라 `rm -rf data/judged` 가 엉뚱한 곳을 가리키고 프롬프트도 못 읽는다.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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
  # `--allowedTools` 는 자동 승인 목록이라 목록 밖 도구를 막지 못한다 — 탐색을 실제로
  # 끊는 것은 `--disallowedTools` 다. </dev/null 은 stdin 을 3초 기다리는 것을 건너뛴다.
  # **권한 모드를 명시한다** — 안 주면 호출자의 `defaultMode` 를 탄다. 오너 머신처럼 `auto` 면
  # 판정 세션이 plan mode 로 들어가 **0 으로 끝나고 아무것도 안 쓴다**(실측). 그 침묵은 아래
  # 출력 파일 검사가 잡지만, 로컬에서 돌려볼 수 있다는 이 스크립트의 목적이 그 자리에서 깨진다.
  claude -p "$ROOT/prompts/classify.md 를 읽고 거기 적힌 지시를 그대로 수행한다. 입력은 $in, 출력은 $out 이다.${CI_NOTE:-}" \
    --model claude-opus-5 \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write" \
    --disallowedTools "Bash,Glob,Grep,WebFetch,WebSearch,Task,ToolSearch" \
    --max-turns 10 \
    < /dev/null
}

failed=''
found=0
for f in "$PENDING_DIR"/*.json; do
  # 매치가 없으면 glob 이 그대로 남는다 — 대기 0인 날 로컬에서 도는 경로다.
  [ -e "$f" ] || break
  found=$((found + 1))
  v=$(basename "$f" .json)
  echo "::group::판정 $v"
  if classify_one "$f" "$JUDGED_DIR/$v.json"; then
    # 판정기가 0 으로 끝나고도 아무것도 안 쓸 수 있다. 그 침묵을 여기서 끊는다.
    test -s "$JUDGED_DIR/$v.json" || {
      echo "::warning::$v — 판정이 0 으로 끝났는데 출력 파일이 없다"
      failed="$failed $v"
    }
  else
    echo "::warning::$v — 판정이 실패로 끝났다"
    failed="$failed $v"
  fi
  echo "::endgroup::"
done

echo "판정한 릴리스 $found"

if [ -n "$failed" ]; then
  echo "::error::판정 실패:$failed"
  exit 1
fi
