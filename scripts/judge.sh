# shellcheck shell=bash
# 판정기 호출 — classify-all.sh 와 area-all.sh 가 함께 쓴다. 판정할 프롬프트만 다르고 호출 방식은 같아야 해서
# 한 곳에 둔다(모델·도구·권한을 바꿀 때 한쪽만 고쳐지지 않게).
#
#   judge_call <프롬프트 파일> <입력 파일> <출력 파일>
#   CI_NOTE        프롬프트 끝에 붙는 메모 (무인 실행임을 알리는 자리).
#   JUDGE_LOG_DIR  주면 호출마다 stream-json 을 `{프롬프트}-{출력 이름}.jsonl` 로 남기고 요약을 낸다.

judge_call() {
  local prompt="$1" in="$2" out="$3"
  # `--allowedTools` 는 자동 승인 목록이라 목록 밖 도구를 막지 못한다 — 탐색을 실제로
  # 끊는 것은 `--disallowedTools` 다. </dev/null 은 stdin 을 3초 기다리는 것을 건너뛴다.
  # **권한 모드를 명시한다** — 안 주면 호출자의 `defaultMode` 를 탄다. 오너 머신처럼 `auto` 면
  # 판정 세션이 plan mode 로 들어가 **0 으로 끝나고 아무것도 안 쓴다**(실측).
  local args=(
    -p "$prompt 를 읽고 거기 적힌 지시를 그대로 수행한다. 입력은 $in, 출력은 $out 이다.${CI_NOTE:-}"
    --model claude-opus-5
    --permission-mode acceptEdits
    --allowedTools "Read,Write"
    --disallowedTools "Bash,Glob,Grep,WebFetch,WebSearch,Task,ToolSearch"
    --max-turns 10
  )
  if [ -z "${JUDGE_LOG_DIR:-}" ]; then
    claude "${args[@]}" < /dev/null
    return
  fi

  mkdir -p "$JUDGE_LOG_DIR"
  local log rc
  log="$JUDGE_LOG_DIR/$(basename "$prompt" .md)-$(basename "$out" .json).jsonl"
  claude "${args[@]}" --output-format stream-json --verbose < /dev/null > "$log"
  rc=$?
  # JSON 이 아닌 줄(CLI 안내 등)이 섞여도 결과 이벤트를 찾도록 줄마다 따로 읽는다. 판정기의 마지막 말은
  # 0 으로 끝나고 아무것도 안 쓴 호출의 이유가 거기 있어 함께 낸다.
  jq -Rer 'fromjson? | select(.type == "result")
    | "판정기: \(.subtype) · 턴 \(.num_turns) · 출력 토큰 \(.usage.output_tokens) · \((.duration_ms // 0) / 1000 | floor)초",
      (.result // "" | gsub("\\s+"; " ") | .[0:300] | select(length > 0) | "  └ \(.)")' \
    "$log" 2>/dev/null || echo "판정기: 결과 이벤트를 읽지 못했다 ($log)"
  return "$rc"
}
