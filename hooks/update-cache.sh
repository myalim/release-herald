#!/usr/bin/env bash
# 캐시 갱신 — 원격의 요약 파일을 로컬 캐시로 옮긴다. 훅이 백그라운드로 띄우고 기다리지 않는다.
#
# 이 스크립트는 **표시 여부를 판단하지 않는다.** 무엇을 띄울지는 세션 시작 훅이 캐시를 읽고
# 정하고, 여기는 "원본 → 로컬 캐시" 이관과 실패 흡수만 맡는다. 그 경계 덕에 갱신 방식이
# 바뀌어도(개인 훅의 gh, 공개 뒤의 curl) 표시 계층은 영향권 밖이다.
#
# 모든 실패는 무음이다 — 오프라인·인증 만료·깨진 응답 어느 쪽이든 기존 캐시를 그대로 두고
# 조용히 끝낸다. 갱신이 늦는 것은 "안 뜸" 으로 나타날 뿐 세션을 방해하지 않는다.
# 진단은 RELEASE_HERALD_DEBUG=1 로 켠다.
#
#   수동 실행: ./hooks/update-cache.sh [--force]
#     --force  쿨다운을 무시하고 즉시 받는다 (진단·초기 설치용)

set -u

CACHE="${RELEASE_HERALD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/release-herald/summaries.json}"
STATE_DIR="${RELEASE_HERALD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/release-herald}"
STAMP="$STATE_DIR/last-update"
LOCK="$STATE_DIR/update.lock"

# 세션을 켤 때마다 네트워크로 나가지 않도록 최소 간격을 둔다. 생성은 하루 한 번(07:00 KST)이라
# 그보다 촘촘히 받아도 얻는 것이 없다.
COOLDOWN="${RELEASE_HERALD_COOLDOWN:-21600}"   # 6시간

# 캐시에 남길 릴리스 개수. **훅의 비용은 파일 크기가 아니라 한 번에 조립하는 미통지 릴리스
# 개수에 비례한다** — 11개를 담으면 최대 밀림 경로가 세션 시작 예산을 넘었고 8개면 절반으로
# 떨어졌다. 원본은 창(9일)보다 넓게 누적해야 하지만 훅이 읽는 캐시는 그럴 이유가 없다.
KEEP="${RELEASE_HERALD_CACHE_KEEP:-8}"

REPO="${RELEASE_HERALD_REPO:-myalim/release-herald}"
# 저장소가 아직 private 이라 인증이 붙는 gh 로 받는다. 공개되면 이 한 줄이 curl 로 바뀌고
# 아래 검증·자르기·교체는 그대로다 — 그래서 받는 경로를 여기 한 곳에 모아 둔다.
REF="${RELEASE_HERALD_REF:-main}"
SRC_PATH="${RELEASE_HERALD_SRC_PATH:-data/summaries.json}"

dbg() { [ -n "${RELEASE_HERALD_DEBUG:-}" ] && printf '[release-herald/update] %s\n' "$*" >&2; return 0; }

FORCE=""
[ "${1:-}" = "--force" ] && FORCE=1

command -v jq >/dev/null 2>&1 || { dbg "jq 없음"; exit 0; }
command -v gh >/dev/null 2>&1 || { dbg "gh 없음"; exit 0; }

# ── 쿨다운 ──────────────────────────────────────────────────────────
# 시각을 파일에 숫자로 적는다 — stat 의 옵션이 macOS 와 Linux 에서 갈리므로 그것에 기대지 않는다.
NOW=$(date +%s)
LAST=0
[ -r "$STAMP" ] && read -r LAST < "$STAMP"
case "$LAST" in '' | *[!0-9]*) LAST=0 ;; esac
if [ -z "$FORCE" ] && [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
  dbg "쿨다운 중 (마지막 갱신 $((NOW - LAST))초 전)"
  exit 0
fi

[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null || { dbg "상태 디렉터리 생성 실패"; exit 0; }

# ── 중복 실행 방지 ──────────────────────────────────────────────────
# 여러 세션을 한꺼번에 켜면 같은 파일을 여러 번 받는다. 결과는 원자적 교체라 안전하지만
# 네트워크가 낭비되므로 막는다. mkdir 은 원자적이라 락으로 쓸 수 있다.
if ! mkdir "$LOCK" 2>/dev/null; then
  # 죽은 프로세스가 남긴 락은 영구히 갱신을 막으므로 오래된 것은 무시한다.
  if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin -10 2>/dev/null)" ]; then
    dbg "오래된 락 제거 후 진행"
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    dbg "다른 인스턴스가 갱신 중"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ── 받기 ────────────────────────────────────────────────────────────
CACHE_DIR="${CACHE%/*}"
[ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null || { dbg "캐시 디렉터리 생성 실패"; exit 0; }

# 임시 파일은 캐시와 **같은 디렉터리**에 만든다 — rename 이 원자적인 것은 같은 파일시스템
# 안에서뿐이라, /tmp 를 거치면 교체 중 부분 상태가 관측될 수 있다.
TMP="$CACHE.fetch.$$"
TRIM="$CACHE.trim.$$"
trap 'rm -f "$TMP" "$TRIM" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT

if ! gh api "repos/$REPO/contents/$SRC_PATH?ref=$REF" \
      -H "Accept: application/vnd.github.raw" > "$TMP" 2>/dev/null; then
  dbg "받기 실패 (오프라인·인증 만료·경로 없음)"
  exit 0
fi

# ── 검증 ────────────────────────────────────────────────────────────
# 받은 것이 요약 파일이 맞는지 본다. 인증이 만료되면 gh 가 JSON 형태의 에러 본문을 200 이
# 아닌 코드와 함께 주지만, 프록시나 로그인 페이지가 200 으로 HTML 을 주는 경우까지 막으려면
# 내용을 봐야 한다. **깨진 것을 캐시에 넣는 것이 안 받는 것보다 나쁘다** — 훅은 캐시를
# 신뢰하고 읽는다.
if ! jq -e '.schema == 1 and (.releases | type) == "array"' "$TMP" >/dev/null 2>&1; then
  dbg "받은 내용이 계약과 다름 — 캐시 유지"
  exit 0
fi

# ── 자르기 + 원자적 교체 ────────────────────────────────────────────
if ! jq --argjson keep "$KEEP" '.releases = .releases[0:$keep]' "$TMP" > "$TRIM" 2>/dev/null; then
  dbg "자르기 실패"
  exit 0
fi

if mv -f "$TRIM" "$CACHE" 2>/dev/null; then
  printf '%s\n' "$NOW" > "$STAMP.tmp" 2>/dev/null && mv -f "$STAMP.tmp" "$STAMP" 2>/dev/null
  dbg "갱신 완료: $(jq -r '.releases | length' "$CACHE" 2>/dev/null)개 릴리스 (원본 ref=$REF)"
else
  dbg "교체 실패"
fi
exit 0
