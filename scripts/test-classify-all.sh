#!/usr/bin/env bash
# classify-all.sh 회귀 테스트 — 판정 루프가 실패를 어떻게 다루나.
#
# **이 네 경로가 이 테스트의 존재 이유다** — 루프가 워크플로 `run:` 안에 있을 때는
# 17분짜리 CI 실행 말고는 밟아볼 방법이 없었고, 그중 "0 으로 끝났는데 출력이 없다" 는
# 실제로 일어나야만 관측됐다. 판정기를 가짜로 바꾸면 넷 다 즉시 재현된다.
#
#   사용법: ./scripts/test-classify-all.sh
#   전제:   없음 (판정기를 부르지 않으므로 네트워크·사용량 0)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/classify-all.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}

# 대기 디렉터리를 새로 짓는다. 내용은 루프가 안 보므로 버전 이름만 맞으면 된다.
seed() { # seed <버전...>
  PEND="$TMP/pending"; JUDGED="$TMP/judged"
  rm -rf "$PEND"; mkdir -p "$PEND"
  for v in "$@"; do echo '{"releases":[]}' > "$PEND/$v.json"; done
}

# 가짜 판정기 — 이름에 따라 성공·침묵·실패를 갈라 낸다. 실제 CLI 자리에 그대로 꽂힌다.
FAKE="$TMP/fake.sh"
cat > "$FAKE" <<'EOF'
#!/bin/sh
# $1 입력 · $2 출력
case "$(basename "$1" .json)" in
  *-silent) exit 0 ;;                 # 0 으로 끝나는데 아무것도 안 쓴다
  *-fail)   exit 1 ;;                 # 판정 자체가 실패
  *)        echo '{"version":"x"}' > "$2" ;;
esac
EOF
chmod +x "$FAKE"

# CMD 로 판정기를 바꾼다 — 빈 값이면 CLASSIFY_CMD 없이 judge_call(가짜 claude) 경로를 밟는다.
run() { CLASSIFY_CMD="${CMD-$FAKE}" "$RUN" "$PEND" "$JUDGED" >"$TMP/out" 2>&1; echo $?; }

echo "── 전부 성공 ──"
seed v2.1.301 v2.1.302
chk "종료코드 0"           "$(run)" "0"
chk "판정 파일이 둘"       "$(find "$JUDGED" -name '*.json' | wc -l | tr -d ' ')" "2"
chk "판정한 개수를 알린다" "$(grep -c '판정 호출 2 ' "$TMP/out")" "1"

echo "── 0 으로 끝났는데 출력이 없다 ──"
seed v2.1.303-silent
chk "종료코드 1"       "$(run)" "1"
chk "침묵을 짚는다"    "$(grep -c '출력 파일이 없다' "$TMP/out")" "1"

echo "── 판정기가 실패로 끝난다 ──"
seed v2.1.304-fail
chk "종료코드 1"       "$(run)" "1"
chk "실패를 짚는다"    "$(grep -c '판정이 실패로 끝났다' "$TMP/out")" "1"

echo "── 일부만 실패 ──"
# **루프가 멈추면 안 되는 자리다** — 한 건이 어긋났다고 뒤 릴리스를 통째로 버리면 정체가 생긴다.
seed v2.1.305 v2.1.306-fail v2.1.307
chk "종료코드 1"                 "$(run)" "1"
chk "성공분은 그대로 남는다"     "$(find "$JUDGED" -name '*.json' | wc -l | tr -d ' ')" "2"
chk "실패한 버전만 보고한다"     "$(grep -c '판정 실패: v2.1.306-fail$' "$TMP/out")" "1"

echo "── 앞선 실행분 ──"
# 지난 실행의 판정이 남아 있으면 이번 실패가 그것에 가려진다.
seed v2.1.308-fail
mkdir -p "$JUDGED"; echo stale > "$JUDGED/v2.1.299.json"
run >/dev/null
chk "묵은 판정 파일을 지운다" "$([ -e "$JUDGED/v2.1.299.json" ] && echo y || echo n)" "n"

echo "── 대기가 0 ──"
# 이 경로가 로컬에서 안 돌면 "판정할 게 없는 날에는 고쳐도 못 돌려본다" 가 그대로 남는다.
seed
chk "종료코드 0"        "$(run)" "0"
chk "0건이라고 알린다"  "$(grep -c '판정 호출 0 ' "$TMP/out")" "1"

echo "── 판정 로그 (JUDGE_LOG_DIR) ──"
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'EOF'
#!/bin/sh
case "$*" in
  *-maxturns.json*) echo '{"type":"result","subtype":"error_max_turns","num_turns":11,"duration_ms":1061042,"usage":{"output_tokens":94675}}'; exit 1 ;;
  *-noresult.json*) echo '{"type":"assistant"}'; exit 0 ;;
  *) echo 'Update available: plain text line'
     echo '{"type":"result","subtype":"success","num_turns":3,"duration_ms":42000,"usage":{"output_tokens":5000},"result":"출력 파일에 썼습니다"}'
     out=$(printf '%s' "$*" | sed 's/.*출력은 \([^ ]*\) 이다.*/\1/'); echo '{}' > "$out" ;;
esac
EOF
chmod +x "$BIN/claude"
seed v2.1.311 v2.1.312-maxturns v2.1.313-noresult
LOGS="$TMP/logs"
chk "종료코드 1"                  "$(CMD='' PATH="$BIN:$PATH" JUDGE_LOG_DIR="$LOGS" run)" "1"
chk "JSON 아닌 줄을 건너뛰고 요약"  "$(grep -c '판정기: success · 턴 3 · 출력 토큰 5000 · 42초' "$TMP/out")" "1"
chk "판정기의 마지막 말"           "$(grep -c '└ 출력 파일에 썼습니다' "$TMP/out")" "1"
chk "턴 상한 요약 한 줄"          "$(grep -c '판정기: error_max_turns · 턴 11 · 출력 토큰 94675 · 1061초' "$TMP/out")" "1"
chk "턴 상한의 종료 코드가 살아남음" "$(grep -c 'v2.1.312-maxturns — 판정이 실패로 끝났다' "$TMP/out")" "1"
chk "결과 이벤트가 없으면 짚음"   "$(grep -c '판정기: 결과 이벤트를 읽지 못했다' "$TMP/out")" "1"
chk "호출마다 로그 파일"          "$(find "$LOGS" -name 'classify-v2.1.31[123]*.jsonl' | wc -l | tr -d ' ')" "3"

echo "── 조각 — 판정을 릴리스 하나로 잇는다 ──"
# 조각 이름(`{버전}@{번호}`)은 build.py `_chunks` 가 낸다.
JOIN="$TMP/join.sh"
cat > "$JOIN" <<'EOF'
#!/bin/sh
[ "$(basename "$1" .json)" = "${FAIL_PART:-}" ] && exit 1
jq '.releases[0].items |= map(. + {impact: "user", weight: 3, ko: "수정"})' "$1" > "$2"
EOF
chmod +x "$JOIN"
seed_chunks() { # 90항목 릴리스를 조각 셋(40·40·10)으로, 5항목 릴리스는 통짜로 둔다
  seed
  python3 - "$PEND" <<'PY'
import json, sys
d = sys.argv[1]
def rel(v, lo, hi):
    return {"releases": [{"version": v, "date": "2026-11-16", "url": "u",
                          "items": [{"kind": "fixed", "en": f"item {i}"} for i in range(lo, hi)]}]}
for n, (lo, hi) in enumerate([(0, 40), (40, 80), (80, 90)], 1):
    json.dump(rel("v9.0.90", lo, hi), open(f"{d}/v9.0.90@{n:03d}.json", "w"))
json.dump(rel("v9.0.5", 0, 5), open(f"{d}/v9.0.5.json", "w"))
PY
}
top() { find "$JUDGED" -maxdepth 1 -name '*.json' | wc -l | tr -d ' '; }

seed_chunks
chk "종료코드 0"                      "$(CMD="$JOIN" run)" "0"
chk "판정 파일은 릴리스마다 하나"     "$(top)" "2"
chk "이은 항목 수가 원래대로"         "$(jq '.releases[0].items | length' "$JUDGED/v9.0.90.json")" "90"
chk "이은 순서가 원래대로"            "$(jq -r '[.releases[0].items[].en] | (.[0] + "," + .[89])' "$JUDGED/v9.0.90.json")" "item 0,item 89"
chk "릴리스 필드는 하나만"            "$(jq '.releases | length' "$JUDGED/v9.0.90.json")" "1"

seed_chunks
chk "조각 하나가 실패하면 종료코드 1" "$(CMD="$JOIN" FAIL_PART='v9.0.90@002' run)" "1"
chk "그 릴리스는 판정 파일이 없음"    "$([ -e "$JUDGED/v9.0.90.json" ] && echo y || echo n)" "n"
chk "다른 릴리스는 그대로"            "$(top)" "1"
chk "실패한 조각을 이름으로 짚음"     "$(grep -c '판정 실패: v9.0.90@002$' "$TMP/out")" "1"
chk "잇지 않았다고 알린다"            "$(grep -c 'v9.0.90 — 실패한 조각이 있어 잇지 않는다' "$TMP/out")" "1"

# 뒤 릴리스를 판정하던 중 단계 시간 제한으로 루프가 끊겨도, 앞서 조각을 다 마친 릴리스는 이어져 있어야 한다.
seed_chunks
echo '{}' > "$PEND/v9.1.0.json"
KILL="$TMP/kill.sh"
cat > "$KILL" <<'EOF'
#!/bin/sh
case "$1" in *v9.1.0*) kill -TERM "$PPID"; sleep 1 ;; *) exec "$JOIN" "$@" ;; esac
EOF
chmod +x "$KILL"
( CMD="$KILL" JOIN="$JOIN" run ) >/dev/null 2>&1
chk "끊기기 전에 마친 릴리스는 이어져 있음" "$(jq '.releases[0].items | length' "$JUDGED/v9.0.90.json" 2>/dev/null)" "90"

echo "── 대기 디렉터리가 없다 ──"
PEND="$TMP/없는디렉터리"; JUDGED="$TMP/judged2"
chk "종료코드 2" "$(run)" "2"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
