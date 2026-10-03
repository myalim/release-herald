#!/usr/bin/env bash
# update-cache.sh 회귀 테스트 — 네트워크 없이 전 흐름을 밟는다.
#
# **`gh` 를 스텁으로 갈아끼워 받는 단계를 흉내낸다.** 진짜 원격에 기대면 테스트가 네트워크
# 상태와 인증 만료에 흔들리고, 무엇보다 **실패 경로를 재현할 수 없다** — 계약과 다른 200
# 응답이나 인증 만료를 실제로 만들어낼 방법이 없기 때문이다. 이 스크립트가 확인하는 것은
# "받은 뒤에 무엇을 하는가"(검증·자르기·원자적 교체·쿨다운·락·조건부 요청)이고, 실제 원격과 붙는지는
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

# gh 스텁 — 실제 `gh api -i` 처럼 상태 줄(LF)·헤더(CRLF, 이름은 실제대로 `Etag`)·빈 줄("\r")·본문을
# 뱉는다. 본문은 $TMP/gh-response, ETag 는 그 내용의 cksum 이라 응답을 바꾸면 ETag 도 따라 바뀐다. If-None-Match 가 현재 ETag 와
# 같으면 실제 gh 처럼 304 를 내고 종료코드 1 로 끝난다. $TMP/gh-exit 이 0 이 아니면 아무것도
# 안 뱉고 그 코드로 끝난다(오프라인). $TMP/gh-noetag 가 있으면 ETag 헤더를 빼고, 받은 인자는
# $TMP/gh-args 에 한 줄씩 남긴다.
cat > "$STUB_DIR/gh" <<'STUB'
#!/bin/sh
D="$TMPDIR_FOR_STUB"
printf '%s\n' "$*" >> "$D/gh-args"
code=$(cat "$D/gh-exit" 2>/dev/null || echo 0)
[ "$code" -ne 0 ] && exit "$code"
etag="\"$(cksum < "$D/gh-response" | awk '{print $1}')\""
case "$*" in
  *"If-None-Match: $etag"*)
    printf 'HTTP/2.0 304 Not Modified\nEtag: %s\r\n\r\n' "$etag"; exit 1 ;;
esac
printf 'HTTP/2.0 200 OK\n'
[ -e "$D/gh-noetag" ] || printf 'Etag: %s\r\n' "$etag"
printf 'Content-Type: text/plain\r\n\r\n'
cat "$D/gh-response"
STUB
chmod +x "$STUB_DIR/gh"
export TMPDIR_FOR_STUB="$TMP"

PASS=0; FAIL=0
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
        else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi; }

run() { # run [--force] — 쿨다운은 $T_COOLDOWN(기본 1시간)
  PATH="$STUB_DIR:$PATH" \
  RELEASE_HERALD_COOLDOWN="${T_COOLDOWN:-3600}" \
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

# 보관 개수는 훅의 세션 시작 예산을 지키는 값이라, 손잡이가 죽으면 예산이 조용히 깨진다.
PATH="$STUB_DIR:$PATH" RELEASE_HERALD_CACHE="$CACHE" RELEASE_HERALD_STATE_DIR="$STATE_DIR" \
  RELEASE_HERALD_CACHE_KEEP=2 "$UPDATER" --force >/dev/null 2>&1
chk "보관 개수 손잡이가 반영됨" "$(count)" "2"
run --force

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

echo "── 조건부 요청 (ETag) ──"
# 쿨다운이 풀린 회차를 흉내내려고 쿨다운 0 으로 부른다(--force 는 조건을 건너뛰므로 쓰지 않는다).
ETAG_F="$STATE_DIR/etag"
last_args() { tail -1 "$TMP/gh-args"; }
cp "$SRC" "$TMP/gh-response"
run --force
chk "받으면 ETag 기록"              "$([ -s "$ETAG_F" ] && echo y || echo n)" "y"
chk "--force 는 조건 없이 받음"     "$(last_args | grep -c 'If-None-Match')" "0"

echo 0 > "$STATE_DIR/last-update"
CACHE_SUM="$(cksum < "$CACHE")"
T_COOLDOWN=0 run
chk "원본 그대로면 조건부로 물음"    "$(last_args | grep -c 'If-None-Match')" "1"
chk "304 → 캐시 그대로"             "$(cksum < "$CACHE")" "$CACHE_SUM"
chk "304 도 갱신 시각을 남김"        "$([ "$(cat "$STATE_DIR/last-update")" -gt 0 ] && echo y || echo n)" "y"

jq '.releases = .releases[0:3]' "$SRC" > "$TMP/gh-response"
OLD_ETAG="$(cat "$ETAG_F")"
T_COOLDOWN=0 run
chk "원본이 바뀌면 200 으로 받음"    "$(count)" "3"
chk "ETag 도 새 값으로 바뀜"         "$([ "$(cat "$ETAG_F")" != "$OLD_ETAG" ] && echo y || echo n)" "y"

# 캐시가 깨졌는데 ETag 만 남은 상태 — 조건부로 물으면 304 가 와서 영영 못 받는다.
printf 'broken' > "$CACHE"
T_COOLDOWN=0 run
chk "캐시가 깨지면 조건 없이 물음"   "$(last_args | grep -c 'If-None-Match')" "0"
chk "깨진 캐시가 복구됨"             "$(count)" "3"
rm -f "$CACHE"
T_COOLDOWN=0 run
chk "캐시가 없어도 조건 없이 받음"   "$(count)" "3"

# 받기 실패는 ETag 도 건드리지 않는다 — 캐시와 짝이 유지돼야 한다.
KEEP_ETAG="$(cat "$ETAG_F")"
echo 1 > "$TMP/gh-exit"
T_COOLDOWN=0 run
chk "받기 실패 → ETag 유지"          "$(cat "$ETAG_F")" "$KEEP_ETAG"
echo 0 > "$TMP/gh-exit"

# 계약과 다른 200 은 교체하지 않으므로 ETag 도 옛 캐시의 것이 남아야 한다.
printf '{"schema":2,"releases":[]}' > "$TMP/gh-response"
T_COOLDOWN=0 run
chk "계약 불일치 → ETag 유지"        "$(cat "$ETAG_F")" "$KEEP_ETAG"
chk "계약 불일치 → 캐시 유지"        "$(count)" "3"

# ETag 헤더 없이 받으면 옛 ETag 를 지운다 — 남기면 새 캐시가 옛 원본의 ETag 와 짝지어진다.
cp "$SRC" "$TMP/gh-response"
touch "$TMP/gh-noetag"
T_COOLDOWN=0 run
chk "ETag 없는 응답 → 기록 지움"     "$([ -e "$ETAG_F" ] && echo y || echo n)" "n"
chk "ETag 없는 응답도 캐시 교체"     "$(count)" "8"
rm -f "$TMP/gh-noetag"

echo "── 뒷정리 ──"
chk "임시 파일 안 남김" "$(find "$TMP/cache" -name '*.fetch.*' -o -name '*.trim.*' -o -name '*.resp.*' | wc -l | tr -d ' ')" "0"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
