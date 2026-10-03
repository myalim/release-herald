#!/usr/bin/env bash
# 영역 경로 회귀 테스트 — 영역 없는 릴리스를 고르고(area-pending), 묻고(area-all.sh), 붙이는(attach-area)
# 전 과정.
#
# **이 경로가 지키는 약속은 넷이다** — 판정기가 원문만 보는 것, 영역 말고 아무것도 바꾸지 않는 것,
# 못 붙인 릴리스가 영역 없이 남아 다음 실행에서 다시 대상이 되는 것, 그 실패를 한 곳에서만 알리는 것.
# 판정기를 스텁으로 바꾸면 실제로 나올 수 있는 어긋남을 사용량 없이 재현한다.
#
#   사용법: ./scripts/test-area-all.sh
#   전제:   python3 · jq · data/summaries.json (fixture 원본)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../data/summaries.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}

S="$TMP/summaries.json"; PEND="$TMP/pending"; AREAS="$TMP/areas"
seed() { jq 'del(.releases[].items[].area)' "$SRC" > "$S"; cp "$S" "$TMP/orig.json"; }

# 스텁 판정기 — $STUB_MODE 로 출력 형태를 고른다. 받은 입력의 항목 키를 남겨 무엇을 봤는지 확인한다.
cat > "$TMP/stub" <<'STUB'
#!/bin/sh
in="$1"; out="$2"
jq -c '[.items[] | keys] | add // [] | unique' "$in" > "$SEEN"
n=$(jq '.items | length' "$in"); v=$(jq -r '.version' "$in")
case "$STUB_MODE" in
  ok)      jq -n --arg v "$v" --argjson n "$n" '{version:$v, areas:[range($n) | ["hooks"]]}' > "$out" ;;
  two)     jq -n --arg v "$v" --argjson n "$n" '{version:$v, areas:[range($n) | ["hooks","mcp"]]}' > "$out" ;;
  short)   jq -n --arg v "$v" --argjson n "$n" '{version:$v, areas:[range($n - 1) | ["hooks"]]}' > "$out" ;;
  badval)  jq -n --arg v "$v" --argjson n "$n" '{version:$v, areas:([range($n) | ["hooks"]] | .[0] = ["security"])}' > "$out" ;;
  wrongv)  jq -n --argjson n "$n" '{version:"v0.0.0", areas:[range($n) | ["hooks"]]}' > "$out" ;;
  broken)  printf '{"version":' > "$out" ;;
  silent)  : ;;
  fail)    exit 1 ;;
esac
STUB
chmod +x "$TMP/stub"
export AREA_CMD="$TMP/stub" SEEN="$TMP/seen"

build() { python3 "$HERE/build.py" "$@"; }
pick()  { build area-pending --summaries "$S" --out-dir "$PEND" "$@" >/dev/null; find "$PEND" -name '*.json' | wc -l | tr -d ' '; }
# 고른 릴리스의 버전들 — 입력 파일 안의 version 으로 읽는다(파일명이 아니라 내용이 대상이다).
picked() { cat "$PEND"/*.json 2>/dev/null | jq -r .version | sort -V; }
tag()   { STUB_MODE="$1" "$HERE/area-all.sh" "$PEND" "$AREAS" >/dev/null 2>&1; echo $?; }
# stderr(영역 미부착 보고)만 잡고 stdout 은 버린다 — 순서가 그 뜻이라 뒤집으면 안 된다.
# shellcheck disable=SC2069
attach() { build attach-area --pending-dir "$PEND" --areas-dir "$AREAS" --summaries "$S" 2>&1 >/dev/null; }
tagged_releases() { jq '[.releases[] | select((.items | length) > 0 and all(.items[]; has("area")))] | length' "$S"; }
others_same() { # 영역을 뺀 나머지가 원본 그대로인가
  jq -S 'del(.releases[].items[].area) | del(.generated)' "$S" > "$TMP/a"; jq -S 'del(.generated)' "$TMP/orig.json" > "$TMP/b"
  cmp -s "$TMP/a" "$TMP/b" && echo y || echo n
}

echo "── 고르기 ──"
seed
chk "상한만큼 고름"                       "$(pick --limit 3)" "3"
chk "최신부터 고름"                       "$(picked | tail -1)" "$(jq -r '.releases[0].version' "$S")"
chk "입력에는 원문만"                     "$(cat "$PEND"/*.json | jq -c '[.items[] | keys] | add | unique' | sort -u)" '["en"]'
EMPTY="$(jq '[.releases[] | select((.items | length) == 0)] | length' "$S")"
ALL="$(jq '.releases | length' "$S")"
chk "항목 0개 릴리스는 고르지 않음"       "$(pick)" "$((ALL - EMPTY))"

echo "── 정상 ──"
seed; pick --limit 3 >/dev/null
chk "영역 단계 종료 코드 0"               "$(tag ok)" "0"
chk "판정기는 원문만 받음"                "$(cat "$TMP/seen")" '["en"]'
OUT="$(attach)"
chk "고른 릴리스에 영역이 붙음"           "$(tagged_releases)" "3"
chk "영역 말고는 그대로"                  "$(others_same)" "y"
chk "영역 미부착 보고 없음"               "$(printf '%s' "$OUT" | grep -c '영역 미부착')" "0"
chk "결과가 계약을 지킴"                  "$(build validate "$S" >/dev/null 2>&1 && echo y || echo n)" "y"
chk "다시 고르면 붙은 릴리스는 빠짐"      "$(pick --limit 3 >/dev/null; jq -r .version "$PEND"/*.json | grep -cxF -f <(jq -r '.releases[] | select((.items|length)>0 and all(.items[]; has("area"))) | .version' "$S"))" "0"

echo "── 어긋난 영역 — 붙지 않고, 남아서 다음에 다시 대상, 한 번 알린다 ──"
for mode in two short badval wrongv broken silent fail; do
  seed; pick --limit 1 >/dev/null; V="$(picked)"
  chk "$mode → 영역 단계는 0 으로 끝남"   "$(tag "$mode")" "0"
  OUT="$(attach)"
  chk "$mode → 영역이 붙지 않음"          "$(tagged_releases)" "0"
  chk "$mode → 파일은 그대로"             "$(others_same)" "y"
  chk "$mode → 영역 미부착 한 줄"         "$(printf '%s' "$OUT" | grep -c "영역 미부착: $V")" "1"
  chk "$mode → 다음에 다시 대상"          "$(pick --limit 1 >/dev/null; picked)" "$V"
done

echo "── 앞선 실행분이 섞이지 않는다 ──"
seed; pick --limit 1 >/dev/null; mkdir -p "$AREAS"; echo '{"version":"v9.9.9","areas":[]}' > "$AREAS/v9.9.9.json"
tag ok >/dev/null
chk "이전 영역 파일이 지워짐"             "$([ -e "$AREAS/v9.9.9.json" ] && echo y || echo n)" "n"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
