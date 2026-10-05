#!/usr/bin/env bash
# watch-pipeline.sh 회귀 테스트 — 언제 이슈를 열고, 언제 침묵하고, 언제 닫나.
#
# 경보는 실제로 멈춰야만 밟히는 경로라, 가짜 `gh` 로 그 상태를 만들어 밟는다. 특히 둘이 이 테스트의
# 존재 이유다 — 같은 경보를 3시간마다 댓글로 쌓지 않는가(소음), 창 밖으로 나간 릴리스로 경보를 영영
# 내지 않는가(되찾을 수 없는 것).
#
#   사용법: ./scripts/test-watch-pipeline.sh
#   전제:   jq (네트워크·GitHub 호출 없음)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/watch-pipeline.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}

# 가짜 gh — 호출을 로그에 남기고, 상류 릴리스·열린 이슈·이슈 표식은 파일로 받는다.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/bin/sh
# 본문이 여러 줄이라 한 호출을 한 줄로 펴서 남긴다 — 그래야 호출마다 grep 으로 갈린다.
printf '%s ' "$@" | tr '\n' ' ' >> "$FAKE/log"; echo >> "$FAKE/log"
case "$1 $2" in
  "api repos/"*)   [ -f "$FAKE/upstream_fail" ] && exit 1; cat "$FAKE/upstream" ;;
  "issue list")    cat "$FAKE/open" 2>/dev/null ;;
  "issue view")    cat "$FAKE/last" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$TMP/bin/gh"

NOW=$(jq -n '"2026-10-20T00:00:00Z" | fromdateiso8601')
DAY=86400
iso() { jq -nr --argjson t "$1" '$t | todateiso8601'; }

# 요약에는 v1 만 있다.
echo '{"releases":[{"version":"v1"}]}' > "$TMP/summaries.json"

# 시나리오를 새로 깐다 — 상류 릴리스 줄들 · 열린 이슈 번호 · 그 이슈의 마지막 표식.
setup() { # setup <열린 이슈|""> <마지막 표식|""> <상류 줄...>
  export FAKE="$TMP/fake"; rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/log"
  [ -n "$1" ] && echo "$1" > "$FAKE/open"
  [ -n "$2" ] && echo "$2" > "$FAKE/last"
  shift 2
  : > "$FAKE/upstream"
  for l in "$@"; do echo "$l" >> "$FAKE/upstream"; done
}
run() { # run <RESULT>
  PATH="$TMP/bin:$PATH" RESULT="$1" REPO=o/r OWNER=me NOW="$NOW" \
    SUMMARIES="$TMP/summaries.json" bash "$RUN" >/dev/null 2>&1
}
calls() { grep -c "$1" "$FAKE/log" | tr -d ' '; }

echo "정상 — 아무것도 안 한다"
setup "" "" "v1 $(iso $((NOW - 5*DAY)))"
run success
chk "이슈 생성 없음" "$(calls 'issue create')" 0
chk "댓글 없음" "$(calls 'issue comment')" 0

echo "실패 — 열린 이슈가 없으면 연다"
setup "" "" "v1 $(iso $((NOW - 5*DAY)))"
run failure
chk "이슈 생성" "$(calls 'issue create')" 1
chk "오너 멘션" "$(grep 'issue create' "$FAKE/log" | grep -c '@me')" 1
chk "표식 failure" "$(grep 'issue create' "$FAKE/log" | grep -c 'watch:failure')" 1

echo "같은 경보가 이어지면 댓글을 쌓지 않는다"
setup 7 failure "v1 $(iso $((NOW - 5*DAY)))"
run failure
chk "댓글 없음" "$(calls 'issue comment')" 0
chk "이슈 생성 없음" "$(calls 'issue create')" 0

echo "경보 종류가 바뀌면 댓글을 단다"
setup 7 failure "v2 $(iso $((NOW - 4*DAY)))"
run success
chk "댓글 1" "$(calls 'issue comment')" 1
chk "새 표식 stale" "$(grep 'issue comment' "$FAKE/log" | grep -c 'watch:stale')" 1

echo "창 경계 — 3일 미만·9일 이상은 세지 않는다"
setup "" "" "v2 $(iso $((NOW - 2*DAY)))" "v3 $(iso $((NOW - 10*DAY)))"
run success
chk "이슈 생성 없음" "$(calls 'issue create')" 0
setup "" "" "v2 $(iso $((NOW - 3*DAY)))"
run success
chk "정확히 3일은 센다" "$(calls 'issue create')" 1

echo "복구 — 열린 이슈를 닫는다"
setup 7 stale "v1 $(iso $((NOW - 5*DAY)))"
run success
chk "복구 댓글" "$(calls 'issue comment')" 1
chk "닫기" "$(calls 'issue close')" 1

echo "상류 조회 실패 — 지연은 판정하지 않는다"
setup "" "" "v2 $(iso $((NOW - 5*DAY)))"
touch "$FAKE/upstream_fail"
run success
chk "이슈 생성 없음" "$(calls 'issue create')" 0

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
