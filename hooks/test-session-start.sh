#!/usr/bin/env bash
# session-start.sh 회귀 테스트 — 실제 세션을 켜지 않고 밟을 수 있는 경로 전부.
#
# 이 훅은 **모든 실패가 침묵으로 수렴하는** 설계라, 고장과 정상 침묵이 겉으로 같다.
# 그래서 "안 떴다" 를 눈으로 확인하는 것으로는 회귀를 잡을 수 없고, 각 침묵이 **어느 이유의**
# 침묵인지를 기록 파일 상태까지 함께 봐야 갈린다. 아래 단언들이 그 짝을 이룬다.
#
# 실제 세션이 필요한 것(resume·compact 에서 안 뜨는가, 사용자가 잘린 항목을 물었을 때 답하는가)은
# 여기서 다루지 않는다 — SPEC 검증 게이트의 표시 측 목록이 그 자리다.
#
#   사용법: ./hooks/test-session-start.sh
#   전제:   jq · data/summaries.json (fixture 원본으로 쓴다)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/session-start.sh"
SRC="$HERE/../data/summaries.json"

command -v jq >/dev/null 2>&1 || { echo "jq 가 필요합니다"; exit 2; }
[ -r "$SRC" ] || { echo "fixture 원본이 없습니다: $SRC"; exit 2; }

# 갱신은 끈다 — 테스트가 실제 네트워크를 치고 사용자의 진짜 캐시를 갈아치우면
# 그것은 검증이 아니라 부작용이다.
export RELEASE_HERALD_NO_UPDATE=1
# 실행 버전도 끈다 — Claude Code 안에서 돌리면 그 세션의 `AI_AGENT` 가 물려 들어와 기대값이 갈린다.
unset AI_AGENT

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"

# fixture — 원본에서 파생시킨다. 실제 데이터로 도는 것이 요점이라 손으로 만든 표본을 쓰지 않는다.
CACHE="$TMP/cache.json";  cp "$SRC" "$CACHE"
BROKEN="$TMP/broken.json"; printf '{"schema":1,"releases":[' > "$BROKEN"
SCHEMA2="$TMP/schema2.json"; jq '.schema = 2' "$CACHE" > "$SCHEMA2"
# weight 1 이 0건인 묶음 — 보충 경로 셋. 아래 버전의 항목 분포가 곧 갈래다:
# v2.1.250 은 weight 3 하나뿐 · v2.1.276 은 weight 2 하나 · v2.1.258 은 weight 2 둘.
W3="$TMP/w3.json"; jq '.releases = [.releases[] | select(.version=="v2.1.250" or .version=="v2.1.248")]' "$CACHE" > "$W3"
# 체감 항목이 0인 릴리스만 미통지가 되는 형태. 실제 데이터에 그런 릴리스는 가장 오래된 끝에만
# 있어 앞에 기록을 세울 자리가 없으므로, 위 묶음의 항목을 전부 internal 로 바꿔 만든다.
W0="$TMP/w0.json"; jq '.releases[0].items |= map(.impact = "internal")' "$W3" > "$W0"
W2A="$TMP/w2a.json"; jq '.releases = [.releases[] | select(.version=="v2.1.276" or .version=="v2.1.275")]' "$CACHE" > "$W2A"
W2B="$TMP/w2b.json"; jq '.releases = [.releases[] | select(.version=="v2.1.258" or .version=="v2.1.257")]' "$CACHE" > "$W2B"
# 여러 버전이 함께 밀렸는데 어느 버전에도 weight 1 이 없는 묶음. 실제 데이터에서는 그런 버전이
# 이웃하지 않으므로 둘을 골라 붙인다 — 보충이 묶음 단위로 세고 최신 버전의 항목을 고르는지 본다.
W2M="$TMP/w2m.json"; jq '.releases = [.releases[] | select(.version=="v2.1.276" or .version=="v2.1.258" or .version=="v2.1.257")]' "$CACHE" > "$W2M"
# 미통지가 한 릴리스뿐인 경로. **버전을 고정 지정한다** — 최신 두 개로 만들면 봇이 릴리스를
# 추가할 때마다 대상이 바뀌지만, 과거 릴리스의 항목은 더 변하지 않는다.
W1="$TMP/w1.json"; jq '.releases = [.releases[] | select(.version=="v2.1.261" or .version=="v2.1.260")]' "$CACHE" > "$W1"

# **최신 버전은 데이터에서 뽑는다.** 원본이 fixture 인데 봇이 매일 릴리스를 덧붙이므로,
# 기대값에 버전을 적으면 그 갱신마다 회귀가 깨진다(실제로 v2.1.263 이 들어와 3건이 깨졌다).
LATEST="$(jq -r '.releases[0].version' "$SRC")"

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}
run() { RELEASE_HERALD_CACHE="$1" RELEASE_HERALD_STATE="$STATE" "$HOOK" 2>/dev/null; }
# stderr 만 잡고 stdout 은 버린다 — 순서가 그 뜻이라 뒤집으면 안 된다(SC2069 는 오타를 의심한 것).
# shellcheck disable=SC2069
run_err() { RELEASE_HERALD_CACHE="$1" RELEASE_HERALD_STATE="$STATE" "$HOOK" 2>&1 >/dev/null; }
len() { printf '%s' "$1" | wc -c | tr -d ' '; }

echo "── 침묵 경로 (전부 정상 동작이다) ──"
rm -f "$STATE"
chk "캐시 없음 → 침묵"            "$(len "$(run /nonexistent.json)")" "0"
chk "캐시 없음 → 기록 만들지 않음"  "$([ -f "$STATE" ] && echo y || echo n)" "n"

rm -f "$STATE"
chk "기록 없음 → 침묵 (소급 통지 안 함)" "$(len "$(run "$CACHE")")" "0"
chk "기록 없음 → 기준선만 세움"          "$(cat "$STATE")" "$LATEST"

echo v2.1.247 > "$STATE"
chk "깨진 JSON → 침묵"     "$(len "$(run "$BROKEN")")" "0"
chk "  기록 건드리지 않음"  "$(cat "$STATE")" "v2.1.247"
chk "모르는 스키마 → 침묵"  "$(len "$(run "$SCHEMA2")")" "0"
chk "  기록 건드리지 않음"  "$(cat "$STATE")" "v2.1.247"

echo "── 침묵의 사유 ──"
# **침묵하는지만 보면 이 결함이 안 잡힌다.** 실제로 "미통지분 없음" 을 "캐시가 깨졌다" 로
# 보고한 적이 있고, 침묵 자체는 정상이라 모든 테스트가 통과했다. 진단 경로의 값은
# "조용한가" 가 아니라 "왜 조용한지를 맞게 말하는가" 다.
diag() { RELEASE_HERALD_CACHE="$1" RELEASE_HERALD_STATE="$STATE" RELEASE_HERALD_DEBUG=1 \
         "$HOOK" >/dev/null 2>"$TMP/diag"; tail -1 "$TMP/diag"; }
echo "$LATEST" > "$STATE"; D_NONE="$(diag "$CACHE")"
echo "$LATEST" > "$STATE"; D_SCHEMA="$(diag "$SCHEMA2")"
echo "$LATEST" > "$STATE"; D_BROKEN="$(diag "$BROKEN")"
# case 를 명령 치환에 한 줄로 넣으면 닫는 괄호가 치환의 끝으로 읽혀 깨진다.
has() { case "$2" in *"$1"*) echo y ;; *) echo n ;; esac; }
chk "미통지분 없음을 그렇게 말함"   "$(has "미통지분 없음" "$D_NONE")" "y"
chk "계약 불일치를 그렇게 말함"     "$(has "계약 버전" "$D_SCHEMA")" "y"
chk "파싱 실패를 그렇게 말함"       "$(has "읽지 못했" "$D_BROKEN")" "y"
chk "세 사유가 서로 다름"           "$([ "$D_NONE" != "$D_SCHEMA" ] && [ "$D_SCHEMA" != "$D_BROKEN" ] && [ "$D_NONE" != "$D_BROKEN" ] && echo y || echo n)" "y"

echo "── stderr 오염 (침묵은 stdout 만이 아니다) ──"
rm -f "$STATE";           chk "기록 없음 경로 stderr 없음"  "$(len "$(run_err "$CACHE")")" "0"
echo v2.1.247 > "$STATE"; chk "캐시 없음 경로 stderr 없음"  "$(len "$(run_err /nonexistent.json)")" "0"
echo v2.1.247 > "$STATE"; chk "깨진 캐시 경로 stderr 없음"  "$(len "$(run_err "$BROKEN")")" "0"

echo "── 출력 경로 ──"
echo v2.1.247 > "$STATE"
OUT="$(run "$CACHE")"
chk "미통지분 있음 → 출력"      "$(printf '%s' "$OUT" | jq -e 'has("systemMessage")' >/dev/null && echo y || echo n)" "y"
chk "  화면 8줄 상한"           "$(printf '%s' "$OUT" | jq -r .systemMessage | grep -c '·')" "8"
chk "  잘림을 숨기지 않음"       "$(printf '%s' "$OUT" | jq -r .systemMessage | grep -c '외 .*건')" "1"
chk "  기록 갱신"               "$(cat "$STATE")" "$LATEST"
chk "같은 버전 재실행 → 침묵"    "$(len "$(run "$CACHE")")" "0"

echo v2.1.260 > "$STATE"
chk "1릴리스는 상한에 안 걸림"   "$(run "$W1" | jq -r .systemMessage | grep -c '·')" "4"

echo v2.0.0 > "$STATE"
chk "기록이 캐시 밖 → 최근 3개만" "$(run "$CACHE" | jq -r .systemMessage | grep -c '3개 버전')" "1"

echo v2.1.248 > "$STATE"
OUT="$(run "$W0")"
chk "체감 항목 0 → 화면 침묵"     "$(printf '%s' "$OUT" | jq 'has("systemMessage")')" "false"
chk "  그래도 컨텍스트는 간다"     "$(printf '%s' "$OUT" | jq '.hookSpecificOutput.additionalContext | length > 0')" "true"

echo "── weight 1 이 0건인 묶음의 보충 ──"
sysmsg() { run "$1" | jq -r '.systemMessage // ""'; }
echo v2.1.248 > "$STATE"
OUT="$(sysmsg "$W3")"
chk "weight 3 뿐 → 안내 한 줄"      "$(printf '%s' "$OUT" | grep -c '주요 변경 사항이 없습니다')" "1"
chk "  항목은 띄우지 않음"          "$(printf '%s' "$OUT" | grep -c '·')" "0"
echo v2.1.275 > "$STATE"
OUT="$(sysmsg "$W2A")"
chk "weight 2 하나 → 그 한 줄"      "$(printf '%s' "$OUT" | grep -c '·')" "1"
chk "  보충임을 밝힘"               "$(printf '%s' "$OUT" | grep -c '참고할 만한 변경은 다음과 같습니다')" "1"
echo v2.1.257 > "$STATE"
OUT="$(sysmsg "$W2B")"
chk "weight 2 여럿 → 한 줄만"       "$(printf '%s' "$OUT" | grep -c '·')" "1"
chk "  몇 건 중인지 밝힘"           "$(printf '%s' "$OUT" | grep -c '2건 중 1건입니다')" "1"
echo v2.1.257 > "$STATE"
OUT="$(sysmsg "$W2M")"
chk "여러 버전이 밀려도 묶음으로 셈"  "$(printf '%s' "$OUT" | grep -c '3건 중 1건입니다')" "1"
chk "  최신 버전의 항목을 고름"       "$(printf '%s' "$OUT" | grep -c 'ANTHROPIC_BASE_URL')" "1"
# 보충 줄도 컨텍스트에 있어야 한다 — 아래 불변식 절은 weight 1 경로만 밟으므로 여기서 따로 본다.
echo v2.1.257 > "$STATE"
OUT="$(run "$W2M")"
SUP="$(jq -r '.releases[] | select(.version=="v2.1.276") | [.items[] | select(.impact=="user" and .weight==2)][0].ko' "$W2M")"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')"
chk "  보충 줄도 컨텍스트에 있음"     "$(has "$SUP" "$CTX")" "y"
# 묶음 안 다른 릴리스에 weight 1 이 있으면 보충하지 않는다 — 판정 단위가 릴리스가 아니라 묶음이다.
echo v2.1.275 > "$STATE"
chk "묶음에 weight 1 이 있으면 보충 없음" "$(sysmsg "$CACHE" | grep -c '주요 변경 사항')" "0"

echo "── 실행 버전까지만 통지 ──"
# W2M 은 v2.1.276 · v2.1.258 · v2.1.257 순서다 — 실행을 v2.1.258 에 두면 v2.1.276 이 "아직 안 받음" 이다.
A258=claude-code_2-1-258_harness
A276=claude-code_2-1-276_harness
head1() { sysmsg "$W2M" | head -1; }
BOTH="[release-herald] Claude Code v2.1.258 → v2.1.276 (2개 버전)"
echo v2.1.257 > "$STATE"
OUT="$(AI_AGENT=$A258 run "$W2M")"
chk "실행보다 새 릴리스는 빼고 띄움"   "$(printf '%s' "$OUT" | jq -r .systemMessage | head -1)" "[release-herald] Claude Code v2.1.258"
chk "  컨텍스트에도 싣지 않음"         "$(has "v2.1.276" "$(printf '%s' "$OUT" | jq -r .hookSpecificOutput.additionalContext)")" "n"
chk "  기록은 실행 버전까지"           "$(cat "$STATE")" "v2.1.258"
chk "받은 뒤의 세션에서 뜸"            "$(AI_AGENT=$A276 head1)" "[release-herald] Claude Code v2.1.276"
chk "  기록이 따라 올라감"             "$(cat "$STATE")" "v2.1.276"
# 기록이 실행 버전보다 새다 = 고치기 전에 이미 알렸거나 다른 세션이 새 버전으로 먼저 열었다.
echo v2.1.276 > "$STATE"
chk "기록이 실행보다 새면 침묵"        "$(len "$(AI_AGENT=$A258 run "$W2M")")" "0"
chk "  기록을 되돌리지 않음"           "$(cat "$STATE")" "v2.1.276"
# 실행 버전이 캐시에 없으면(캐시가 늦다 · 값이 엉뚱하다) 예전 판정 그대로다.
echo v2.1.257 > "$STATE"
chk "실행 버전이 캐시에 없으면 예전대로" "$(AI_AGENT=claude-code_9-9-999_harness head1)" "$BOTH"
echo v2.1.257 > "$STATE"
chk "형태가 다른 값도 예전대로"        "$(AI_AGENT=unknown head1)" "$BOTH"
rm -f "$STATE"
AI_AGENT=$A258 run "$W2M" >/dev/null
chk "최초 설치 기준선은 실행 버전"     "$(cat "$STATE")" "v2.1.258"
echo v2.0.0 > "$STATE"
chk "기록이 캐시 밖이면 실행 버전부터 취함" "$(AI_AGENT=$A258 head1)" "[release-herald] Claude Code v2.1.257 → v2.1.258 (2개 버전)"

echo "── 불변식 ──"
echo v2.1.247 > "$STATE"
OUT="$(run "$CACHE")"
CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')"
MISS=0
# grep -q 는 첫 매치에서 끝나 앞의 printf 에 SIGPIPE 를 남긴다. 내장 case 로 본다.
while IFS= read -r line; do
  case "$CTX" in *"$line"*) ;; *) MISS=$((MISS+1)) ;; esac
done < <(printf '%s' "$OUT" | jq -r .systemMessage | grep '·' | sed 's/^  · //')
chk "additionalContext ⊇ systemMessage" "$MISS" "0"

echo "── 단조 증가 가드 ──"
# 훅을 배경으로 띄우고 **실행 중에** 기록을 바꾸면 그 경합을 겨냥할 수 있다. 미리 바꿔 두는
# 방식으로는 안 된다 — 그 값이 LAST 로 읽혀 가드가 아니라 다른 경로를 타기 때문이다.
# 지연은 훅의 "기록 읽기 → 쓰기" 사이를 노린다. 실측에서 그 구간이 5~25ms 였다.
OLDCACHE="$TMP/old.json"
jq '.releases = [.releases[] | select(.version < "v2.1.258")]' "$CACHE" > "$OLDCACHE"
# race <캐시> <시작 기록> <끼어드는 기록> — 지연마다 한 번씩 돌려 한 번이라도 물러났으면 y.
# AI_AGENT 는 호출 앞에 붙여 넘긴다.
race() {
  local d n=0
  for d in 0.005 0.010 0.015 0.020; do
    echo "$2" > "$STATE"
    RELEASE_HERALD_CACHE="$1" RELEASE_HERALD_STATE="$STATE" RELEASE_HERALD_DEBUG=1 \
      "$HOOK" >/dev/null 2>"$TMP/guard.log" &
    gpid=$!
    sleep "$d"
    echo "$3" > "$STATE"
    wait $gpid
    grep -q "물러남" "$TMP/guard.log" && n=$((n+1))
  done
  [ "$n" -gt 0 ] && echo y || echo n
}
# 더 새 캐시를 본 세션이 먼저 썼다.
chk "경합에서 기록이 되돌아가지 않음" "$(race "$OLDCACHE" v2.1.252 v2.1.261)" "y"
# 같은 캐시를 보면서 실행 버전만 다른 경합 — 상대가 쓴 값이 내 캐시에 있는 경우다(이유는 훅의 가드 주석).
chk "  실행 버전이 더 새 세션의 기록도 되돌리지 않음" "$(AI_AGENT=$A258 race "$W2M" v2.1.257 v2.1.276)" "y"
# **가드가 창을 좁힐 뿐 없애지는 못한다** — 읽기와 쓰기 사이(실측 30ms 부근)에 끼어들면
# 그대로 통과한다. 파일 상태에 원자적 비교-교체가 없어서이고, 최악의 결과가 "이미 본
# 릴리스가 한 번 더 뜸" 이라 수용한다. 그 사실을 여기 남겨 다음 사람이 완전 방어로 읽지 않게 한다.


echo "── 조정 손잡이 ──"
# 손잡이는 기본값 경로만 확인하면 깨져도 안 잡힌다 — 값을 바꿔 실제로 반영되는지 본다.
echo v2.1.247 > "$STATE"
chk "화면 줄 수 상한이 반영됨" \
  "$(RELEASE_HERALD_MAX_LINES=3 run "$CACHE" | jq -r .systemMessage | grep -c '·')" "3"
echo v2.1.247 > "$STATE"
chk "  상한을 바꿔도 잘림은 알림"  \
  "$(RELEASE_HERALD_MAX_LINES=3 run "$CACHE" | jq -r .systemMessage | grep -c '외 .*건')" "1"
echo v2.0.0 > "$STATE"
chk "캐시 밖 기록의 취할 개수가 반영됨" \
  "$(RELEASE_HERALD_FRESH_LIMIT=1 run "$CACHE" | jq -r .systemMessage | grep -c '개 버전')" "0"

echo "── 갱신과의 경계 ──"
# **기다리는 것이 계약이다** — 기다리지 않으면 이번 세션이 갱신 전 캐시로 판정해 새 릴리스가
# 한 세션 늦게 뜬다. 오래 걸리는 갱신기를 물려 훅 소요가 그만큼 늘어나는지 본다.
# 상한은 이 스크립트가 아니라 훅 등록의 `timeout` 이 걸므로 여기서 검증하지 않는다.
SLOW="$TMP/slow-updater.sh"
printf '#!/bin/sh\nsleep 3\n' > "$SLOW"; chmod +x "$SLOW"
echo v2.1.260 > "$STATE"
T0=$(date +%s)
# 갱신을 켜려고 빈 값을 넘긴다 — 훅이 `-z` 로 보므로 빈 문자열이 곧 "끄지 않음" 이다.
RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE="$STATE" \
  RELEASE_HERALD_NO_UPDATE='' RELEASE_HERALD_UPDATER="$SLOW" "$HOOK" >/dev/null 2>&1
T1=$(date +%s)
chk "갱신기를 기다린다"       "$([ $((T1 - T0)) -ge 2 ] && echo y || echo n)" "y"
chk "  끝난 뒤에 판정한다"    "$(pgrep -f "$SLOW" >/dev/null && echo y || echo n)" "n"

# 갱신을 끄는 손잡이가 살아 있어야 테스트 자신이 사용자의 진짜 캐시를 건드리지 않는다.
echo v2.1.260 > "$STATE"
T0=$(date +%s)
RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE="$STATE" \
  RELEASE_HERALD_NO_UPDATE=1 RELEASE_HERALD_UPDATER="$SLOW" "$HOOK" >/dev/null 2>&1
T1=$(date +%s)
chk "NO_UPDATE 면 갱신을 안 부른다" "$([ $((T1 - T0)) -lt 2 ] && echo y || echo n)" "y"
pkill -f "$SLOW" 2>/dev/null

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
