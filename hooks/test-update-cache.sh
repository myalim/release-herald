#!/usr/bin/env bash
# update-cache.sh 회귀 테스트 — 네트워크 없이 전 흐름을 밟는다.
#
# **`gh` 를 스텁으로 갈아끼워 받는 단계를 흉내낸다.** 진짜 원격에 기대면 테스트가 네트워크
# 상태와 인증 만료에 흔들리고, 무엇보다 **실패 경로를 재현할 수 없다** — 계약과 다른 200
# 응답이나 인증 만료를 실제로 만들어낼 방법이 없기 때문이다. 이 스크립트가 확인하는 것은
# "받은 뒤에 무엇을 하는가"(검증·자르기·원자적 교체·쿨다운·락)이고, 실제 원격과 붙는지는
# 수동 실행과 SPEC 검증 게이트가 본다.
#
#   사용법: ./hooks/test-update-cache.sh

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
UPDATER="$HERE/update-cache.sh"
SRC="$HERE/../data/summaries.json"

command -v jq >/dev/null 2>&1 || { echo "jq 가 필요합니다"; exit 2; }
[ -r "$SRC" ] || { echo "fixture 원본이 없습니다: $SRC"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CACHE="$TMP/cache/summaries.json"
STATE_DIR="$TMP/state"
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"

# gh 스텁 — $TMP/gh-response 의 내용을 뱉고 $TMP/gh-exit 의 코드로 끝난다.
cat > "$STUB_DIR/gh" <<'STUB'
#!/bin/sh
code=$(cat "$TMPDIR_FOR_STUB/gh-exit" 2>/dev/null || echo 0)
[ "$code" -ne 0 ] && exit "$code"
cat "$TMPDIR_FOR_STUB/gh-response"
STUB
chmod +x "$STUB_DIR/gh"
export TMPDIR_FOR_STUB="$TMP"

PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
        else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi; }

run() { # run [--force]
  PATH="$STUB_DIR:$PATH" \
  RELEASE_HERALD_CACHE="$CACHE" \
  RELEASE_HERALD_STATE_DIR="$STATE_DIR" \
    "$UPDATER" "$@" >/dev/null 2>&1
}
count() { jq -r '.releases | length' "$CACHE" 2>/dev/null || echo "-"; }

echo 0 > "$TMP/gh-exit"
cp "$SRC" "$TMP/gh-response"

echo "── 정상 경로 ──"
run --force
chk "캐시 생성됨"            "$([ -f "$CACHE" ] && echo y || echo n)" "y"
chk "보관 상한(8) 적용"      "$(count)" "8"
chk "최신 우선 정렬 보존"     "$(jq -r '.releases[0].version' "$CACHE")" "$(jq -r '.releases[0].version' "$SRC")"
chk "갱신 시각 기록"          "$([ -s "$STATE_DIR/last-update" ] && echo y || echo n)" "y"

echo "── 쿨다운 ──"
# 원격 내용을 바꿔 두고 부른다. 쿨다운이 걸리면 캐시가 그대로여야 한다.
jq '.releases = .releases[0:2]' "$SRC" > "$TMP/gh-response"
run
chk "쿨다운 중에는 받지 않음"  "$(count)" "8"
run --force
chk "--force 는 쿨다운 무시"   "$(count)" "2"
cp "$SRC" "$TMP/gh-response"

echo "── 실패 경로 (전부 캐시를 지켜야 한다) ──"
run --force   # 정상 상태로 되돌림
BEFORE="$(count)"

echo 1 > "$TMP/gh-exit"
run --force
chk "받기 실패 → 캐시 유지"    "$(count)" "$BEFORE"
echo 0 > "$TMP/gh-exit"

printf '{"schema":2,"releases":[]}' > "$TMP/gh-response"
run --force
chk "모르는 스키마 → 캐시 유지" "$(count)" "$BEFORE"

printf '<!DOCTYPE html><html>login</html>' > "$TMP/gh-response"
run --force
chk "JSON 아닌 응답 → 캐시 유지" "$(count)" "$BEFORE"

printf '{"schema":1}' > "$TMP/gh-response"
run --force
chk "releases 없는 응답 → 캐시 유지" "$(count)" "$BEFORE"
cp "$SRC" "$TMP/gh-response"

echo "── 락 ──"
mkdir -p "$STATE_DIR/update.lock"
jq '.releases = .releases[0:1]' "$SRC" > "$TMP/gh-response"
run --force
chk "락이 있으면 물러남"       "$(count)" "$BEFORE"
rmdir "$STATE_DIR/update.lock"

mkdir -p "$STATE_DIR/update.lock"
touch -t "$(date -v-20M +%Y%m%d%H%M 2>/dev/null || date -d '20 min ago' +%Y%m%d%H%M)" "$STATE_DIR/update.lock"
run --force
chk "오래된 락은 무시하고 진행"  "$(count)" "1"
chk "락 정리됨"                "$([ -d "$STATE_DIR/update.lock" ] && echo y || echo n)" "n"

echo "── 뒷정리 ──"
chk "임시 파일 안 남김" "$(ls "$TMP/cache/" | grep -cE '\.(fetch|trim)\.')" "0"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
