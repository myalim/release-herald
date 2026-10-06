#!/usr/bin/env bash
# show.sh 회귀 테스트 — 조회가 밟는 경로 전부.
#
# 이 도구의 계약은 **게이트를 걸지 않는 것**이다(화면에서 잘린 것을 보러 오는 경로다).
# 그래서 "무엇이 보이나" 만이 아니라 **"화면 규칙이 여기로 새어들지 않았나"** 를 함께 본다 —
# weight 1 이 0건인 릴리스에서 아무것도 안 나오면 그것이 이 도구의 고장이다.
#
#   사용법: ./hooks/test-show.sh
#   전제:   jq · data/summaries.json (fixture 원본으로 쓴다)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SHOW="$HERE/show.sh"
SRC="$HERE/../data/summaries.json"

command -v jq >/dev/null 2>&1 || { echo "jq 가 필요합니다"; exit 2; }
[ -r "$SRC" ] || { echo "fixture 원본이 없습니다: $SRC"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/cache.json"; cp "$SRC" "$CACHE"
STATE="$TMP/state"

# **기대값에 최신 버전을 적지 않는다** — 봇이 릴리스를 덧붙이므로 그때마다 회귀가 깨진다.
# 대신 과거 릴리스를 고정 지정한다(그 항목은 더 변하지 않는다).
LATEST="$(jq -r '.releases[0].version' "$CACHE")"
COUNT="$(jq -r '.releases | length' "$CACHE")"
SHOWN=$(( COUNT > 10 ? 10 : COUNT ))   # 목록 모드는 최신 10개만 보인다
W0="v2.1.258"    # user 항목은 있는데 weight 1 이 0건 — 화면이 침묵하던 형태
INT="v2.1.260"   # impact:internal 항목이 있는 릴리스

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}
run() { RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE="$STATE" "$SHOW" "$@" 2>/dev/null; }
code() { RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE="$STATE" "$SHOW" "$@" >/dev/null 2>&1; echo $?; }
# stderr(왜 실패했는지)만 잡고 stdout 은 버린다 — 순서가 그 뜻이다.
# shellcheck disable=SC2069
err()  { RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE="$STATE" "$SHOW" "$@" 2>&1 >/dev/null; }

echo "── 데이터 선택 ──"

# 배포본 모사 — 스크립트 옆에 원본이 있으면 캐시가 없어도 산다.
mkdir -p "$TMP/pkg/hooks" "$TMP/pkg/data"
cp "$SHOW" "$TMP/pkg/hooks/"; cp "$SRC" "$TMP/pkg/data/summaries.json"
chk "캐시가 없으면 옆의 원본으로 내려간다" \
  "$(RELEASE_HERALD_CACHE=/nonexistent/x.json "$TMP/pkg/hooks/show.sh" 2>/dev/null | grep -c '^  v')" "$SHOWN"

mkdir -p "$TMP/lonely"; cp "$SHOW" "$TMP/lonely/"
RELEASE_HERALD_CACHE=/nonexistent/x.json "$TMP/lonely/show.sh" >/dev/null 2>&1
chk "둘 다 없으면 실패한다" "$?" "1"
chk "  경로는 기본으로 숨긴다" \
  "$(RELEASE_HERALD_CACHE=/nonexistent/x.json "$TMP/lonely/show.sh" 2>&1 >/dev/null | grep -cE '캐시:|받기:')" "0"
chk "  진단 모드에서는 경로를 보인다" \
  "$(RELEASE_HERALD_DEBUG=1 RELEASE_HERALD_CACHE=/nonexistent/x.json "$TMP/lonely/show.sh" 2>&1 >/dev/null | grep -cE '캐시:|받기:')" "2"
chk "  왜 없는지 말한다" \
  "$(RELEASE_HERALD_CACHE=/nonexistent/x.json "$TMP/lonely/show.sh" 2>&1 >/dev/null | grep -c '읽지 못했습니다')" "1"

echo "── 목록 ──"
chk "릴리스마다 한 줄 (최대 10)" "$(run | grep -c '^  v')" "$SHOWN"
printf '%s\n' "$LATEST" > "$STATE"
chk "통지 기록 마커는 그 버전에만" "$(run | grep -c '← 마지막으로 알린 버전')" "1"
chk "  마커가 기록된 버전에 붙는다" "$(run | grep '← 마지막으로 알린 버전' | grep -c "$LATEST")" "1"
: > "$STATE"
chk "기록이 없으면 마커도 없다" "$(run | grep -c '← 마지막으로 알린 버전')" "0"

echo "── 목록 자르기 ──"
# 경계는 데이터를 잘라 만든다 — 정확히 10개 · 11개 · 그 이하.
lcut() { jq --argjson n "$1" '.releases = .releases[0:$n]' "$SRC" > "$TMP/cut$1.json"; }
lrun() { RELEASE_HERALD_CACHE="$TMP/cut$1.json" RELEASE_HERALD_STATE="$STATE" "$TMP/lonely/show.sh" 2>/dev/null; }
lonly() { RELEASE_HERALD_CACHE="$TMP/cut$1.json" RELEASE_HERALD_STATE="$STATE" "$TMP/lonely/show.sh" "${@:2}" 2>/dev/null; }
: > "$STATE"
lcut 9; lcut 10; lcut 11; lcut 15
chk "9개면 전부, 안내 줄 없음"       "$(lrun 9 | grep -c '^  v')|$(lrun 9 | grep -c '생략')" "9|0"
chk "정확히 10개면 전부, 안내 줄 없음" "$(lrun 10 | grep -c '^  v')|$(lrun 10 | grep -c '생략')" "10|0"
chk "  머리 줄은 기존 문구"           "$(lrun 10 | head -1)" "릴리스 10개 · 최신순"
chk "11개면 최신 10개만 + 안내 한 줄" "$(lrun 11 | grep -c '^  v')|$(lrun 11 | grep -c '생략')" "10|1"
chk "  10개가 최신부터 이어진다"      "$(lrun 11 | grep '^  v' | awk '{print $1}')" "$(jq -r '.releases[0:10][].version' "$TMP/cut11.json")"
chk "  머리 줄이 전체와 보인 개수를 말한다" "$(lrun 11 | head -1)" "릴리스 11개 중 최신 10개 · 최신순"
chk "  생략 개수를 말한다"            "$(lrun 15 | grep '생략' | grep -c '이전 릴리스 5개')" "1"
HINT="$(lrun 15 | grep '생략')"
chk "  안내 한 줄에 찾기와 한 릴리스가 있다" "$(grep -c '찾기: /release-herald:show --find 낱말 · 한 릴리스: /release-herald:show [0-9]' <<<"$HINT")" "1"
chk "  찾기 안내는 한 번만 나온다"    "$(lrun 15 | grep -c -- '--find 낱말')|$(lrun 10 | grep -c -- '--find 낱말')" "1|1"
# 안내된 한 릴리스 명령을 그대로 실행하면 생략된 릴리스(가장 최신 것)가 나온다.
ONE="${HINT##*/release-herald:show }"
chk "  안내된 한 릴리스 명령이 생략분을 낸다" "$(lonly 15 "$ONE" | grep -E '^v[0-9][0-9.]* · [0-9]' | awk '{print $1}')" "$(jq -r '.releases[10].version' "$SRC")"
# 마지막으로 알린 버전이 보이는 구간 / 생략 구간에 있을 때.
jq -r '.releases[2].version' "$SRC" > "$STATE"
chk "알린 버전이 보이면 마커가 붙고 생략 안내가 없다" "$(lrun 15 | grep -c '← 마지막으로 알린 버전')|$(lrun 15 | grep -c '은 생략된 구간')" "1|0"
jq -r '.releases[12].version' "$SRC" > "$STATE"
chk "알린 버전이 생략 구간이면 마커 없이 그 사실을 밝힌다" "$(lrun 15 | grep -c '← 마지막으로 알린 버전')|$(lrun 15 | grep -c "$(cat "$STATE").*생략된 구간")" "0|1"
chk "  그 릴리스는 버전 조회로 나온다" "$(lonly 15 "$(cat "$STATE")" | grep -c "^$(cat "$STATE") · ")" "1"
: > "$STATE"
# 끝자리가 보이는 쪽의 다른 릴리스와 겹치면(마이너가 바뀐 뒤) 끝자리로는 엇나간다.
HIDV="$(jq -r '.releases[10].version' "$SRC")"
jq --arg v "v9.9.${HIDV##*.}" '.releases = .releases[0:15] | .releases[0].version = $v' "$SRC" > "$TMP/cutamb.json"
AONE="$(lrun amb | grep '생략' | sed 's/.*한 릴리스: \/release-herald:show //')"
chk "끝자리가 겹치면 안내는 전체 버전으로" "$AONE" "${HIDV#v}"
chk "  그 명령이 생략분을 낸다" "$(lonly amb "$AONE" | grep -E '^v[0-9][0-9.]* · [0-9]' | awk '{print $1}')" "$HIDV"
jq '.releases = []' "$SRC" > "$TMP/cut0.json"
chk "릴리스가 0개여도 오류 없이 머리 줄만" "$(RELEASE_HERALD_CACHE="$TMP/cut0.json" "$TMP/lonely/show.sh" 2>&1 | grep -c 'error')|$(lrun 0 | head -1)" "0|릴리스 0개 · 최신순"
chk "--help 가 목록 상한을 밝힌다" "$("$SHOW" --help | grep -c '최신 10개')" "1"

# **조회가 기록을 소진하면 그 릴리스가 세션 시작에 다시 안 뜬다** — 읽기 전용이 계약이라 회귀로 잡는다.
printf '%s\n' "$LATEST" > "$STATE"
run >/dev/null; run 260 >/dev/null; run 257..258 >/dev/null; run --find 훅 >/dev/null; run --area hooks >/dev/null
chk "조회는 통지 기록을 쓰지 않는다" "$(cat "$STATE")" "$LATEST"

echo "── 캐시 + 원본 ──"
PKG="$TMP/pkg/hooks/show.sh"
jq '.releases = .releases[0:3]' "$SRC" > "$TMP/short.json"
prun() { RELEASE_HERALD_CACHE="$1" RELEASE_HERALD_STATE="$STATE" "$PKG" "${@:2}" 2>/dev/null; }
chk "캐시에 없는 버전도 원본에서 찾는다" "$(prun "$TMP/short.json" "$W0" | grep -c "^$W0 · ")" "1"
LIST="$(prun "$TMP/short.json")"
chk "목록은 둘을 합친 뒤 10개로 자른다" "$(grep -c '^  v' <<<"$LIST")" "$SHOWN"
chk "  머리 줄은 합친 전체 개수를 말한다" "$(head -1 <<<"$LIST" | grep -c "$COUNT")" "1"
chk "  내부 경로를 드러내지 않는다"     "$(grep -cE "summaries.json|$TMP" <<<"$LIST")" "0"
jq --arg v "$W0" '(.releases[] | select(.version == $v) | .items[0].ko) = "캐시판"' "$SRC" > "$TMP/edited.json"
chk "같은 버전은 캐시를 쓴다"           "$(prun "$TMP/edited.json" --all "$W0" | grep -c '캐시판')" "1"
jq '.releases = [.releases[0] | .version = "v9.9.9" | .date = "2099-01-01"] + .releases' "$SRC" > "$TMP/newer.json"
jq '.releases = .releases[1:]' "$SRC" > "$TMP/pkg/data/summaries.json"
chk "합쳐도 최신 우선"                  "$(prun "$TMP/newer.json" | grep '^  v' | head -1 | grep -c 'v9.9.9')" "1"
chk "  범위 자르기가 그 순서를 딛는다"  "$(prun "$TMP/newer.json" 9.9.9.."$W0" | grep -cE '^v[0-9][0-9.]* · [0-9]')" "$(( $(jq --arg v "$W0" '[.releases[].version] | index($v)' "$SRC") + 2 ))"
cp "$SRC" "$TMP/pkg/data/summaries.json"
chk "캐시 밖 릴리스도 찾기로 나온다"    "$(prun "$TMP/short.json" --find 'Remote Control 세션 이름' | grep -c '^  v2.1.268 ')" "1"
echo '{bad' > "$TMP/bad.json"
chk "깨진 캐시는 원본으로 내려간다"     "$(prun "$TMP/bad.json" "$W0" | grep -c "^$W0 · ")" "1"
chk "원본 없이 캐시만 깨졌으면 왜인지 말한다" \
  "$(RELEASE_HERALD_CACHE="$TMP/bad.json" "$TMP/lonely/show.sh" 2>&1 >/dev/null | grep -c '읽지 못했습니다')" "1"

echo "── 버전 지정 ──"
chk "숫자만"        "$(run 260   | grep -c '^v2.1.260 · ')" "1"
chk "v 접두어"      "$(run v2.1.260 | grep -c '^v2.1.260 · ')" "1"
chk "접두어 없는 전체" "$(run 2.1.260  | grep -c '^v2.1.260 · ')" "1"
chk "없는 버전은 실패" "$(code 99999)" "1"
chk "  왜 못 찾았는지 말한다" \
  "$(RELEASE_HERALD_CACHE="$CACHE" "$SHOW" 99999 2>&1 >/dev/null | grep -c '없습니다')" "1"

echo "── 범위 ──"
chk "양끝을 포함한다"   "$(run 257..258 | grep -cE '^v[0-9][0-9.]* · [0-9]')" "2"
chk "역순도 같은 결과"  "$(run 258..257 | grep -cE '^v[0-9][0-9.]* · [0-9]')" "2"
chk "최신 우선 순서"    "$(run 257..258 | grep -E '^v[0-9][0-9.]* · [0-9]' | head -1 | grep -c 'v2.1.258')" "1"

echo "── 게이트를 걸지 않는다 ──"
chk "weight 1 이 0건이어도 항목이 보인다" "$(run "$W0" | grep -c '^   · ')" "2"
chk "  없다는 사실도 밝힌다"              "$(run "$W0" | grep -c '주요 변경 없음')" "1"
chk "화면 대상과 나머지를 나눈다"         "$(run 260 | grep -c '그 밖의 변경')" "1"
chk "그 밖의 변경도 빠짐없이"             "$(run 260 | grep -c '^   · ')" "$(jq --arg v "v2.1.260" '[.releases[]|select(.version==$v)|.items[]|select(.impact=="user")]|length' "$CACHE")"
chk "중요도 코드를 드러내지 않는다"       "$(run --all 260 | grep -c '\[w[0-9]')" "0"

echo "── impact 경계 ──"
chk "internal 은 기본으로 안 보인다" "$(run "$INT" | grep -c '^  내부 변경')" "0"
chk "--all 이면 보인다"              "$(run --all "$INT" | grep -c '^  내부 변경')" "1"

echo "── 찾기 ──"
RC="v2.1.268"   # "Remote Control 세션 이름" 으로 찾혀야 하는 항목이 있는 릴리스 (이 기능을 만든 실제 사례)
chk "낱말이 모두 든 항목이 버전과 함께 나온다" "$(run --find 'Remote Control 세션 이름' | grep -c "^  $RC ")" "1"
chk "  대소문자를 가리지 않는다"     "$(run --find 'remote control 세션 이름' | grep -c "^  $RC ")" "1"
chk "  낱말 하나라도 없으면 안 나온다" "$(code --find 'Remote Control 세션 이름 없는낱말쀍')" "1"
chk "  못 찾으면 왜인지 말한다"      "$(err --find 쀍 | grep -c '맞는 변경이 없습니다')" "1"
VERS="$(run --find 훅 | awk '{print $1}' | uniq)"
chk "  최신부터"                     "$VERS" "$(sort -t. -k3,3nr <<<"$VERS")"
chk "  범위를 주면 그 안에서만"      "$(run --find 훅 270..275 | awk '{print $1}' | grep -cvE '^v2\.1\.27[0-5]$')" "0"
INTWORD="$(jq -r --arg v "$INT" '.releases[]|select(.version==$v)|.items[]|select(.impact=="internal")|.en' "$CACHE" | head -1)"
chk "  internal 은 기본으로 안 찾는다" "$(code --find "$INTWORD" "$INT")" "1"
chk "  --all 이면 찾는다"            "$(run --all --find "$INTWORD" "$INT" | grep -c ' · 내부\]')" "1"

echo "── 영역 ──"
HOOKS_N="$(jq '[.releases[] | select(.version | ltrimstr("v2.1.") | tonumber | . >= 270 and . <= 275) | .items[] | select(.impact=="user" and .area==["hooks"])] | length' "$CACHE")"
chk "그 영역 항목만 나온다"          "$(run --area hooks 270..275 | grep -c '\[hooks\]')" "$HOOKS_N"
chk "  다른 영역은 섞이지 않는다"    "$(run --area hooks 270..275 | grep -vc '\[hooks\]')" "0"
chk "찾기와 함께 쓰면 둘 다 맞아야"  "$(run --area remote-control --find '세션 이름' | grep -c "^  $RC ")" "1"
chk "  다른 영역이면 안 나온다"      "$(code --area hooks --find 'Remote Control 세션 이름')" "1"
chk "없는 영역은 실패"               "$(code --area hook)" "2"
chk "  있는 영역을 보여 준다"        "$(err --area hook | grep -c '있는 영역: .*hooks')" "1"
# 영역이 붙기 전 캐시도 읽힌다 — 걸리지 않을 뿐 찾기는 된다.
jq 'del(.releases[].items[].area)' "$SRC" > "$TMP/noarea.json"
chk "영역 없는 항목은 그렇게 표시"   "$(RELEASE_HERALD_CACHE="$TMP/noarea.json" RELEASE_HERALD_STATE="$STATE" "$TMP/lonely/show.sh" --find 'Remote Control 세션 이름' 2>/dev/null | grep -c '영역 없음')" "1"

echo "── 옵션 ──"
chk "--en 이 원문을 붙인다" "$(run --en "$W0" | grep -c '^       [A-Z]')" "2"
chk "옵션 순서는 무관"      "$(run "$W0" --en | grep -c '^       [A-Z]')" "2"
chk "모르는 옵션은 실패"    "$(code --nope)" "2"
chk "대상 중복도 실패"      "$(code 260 261)" "2"
chk "--help 는 성공"        "$(code --help)" "0"
chk "--find 값이 없으면 실패"   "$(code --find)" "2"
chk "--find 공백만이면 실패"    "$(code --find '   ')" "2"
chk "--area 뒤 옵션을 값으로 삼키지 않는다" "$(code --area --all)" "2"
FLAG="$(jq -r '[.releases[].items[] | select(.impact=="user") | .en | scan("--[a-z][a-z-]+")][0]' "$CACHE")"
# 출력은 ko 만 보이고 맞추기는 ko·en 을 합쳐 하므로, 줄에서 낱말을 찾지 않고 건수를 데이터와 댄다.
WANT="$(jq --arg f "$FLAG" '[.releases[].items[] | select(.impact=="user" and ((.ko + " " + .en) | ascii_downcase | contains($f)))] | length' "$CACHE")"
chk "--find 는 플래그 이름도 낱말로 받는다" "$(run --find "$FLAG" | grep -c '^  v')" "$WANT"

echo
printf '통과 %d · 실패 %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
