#!/usr/bin/env bash
# 캐시 갱신 — 원격의 요약 파일을 로컬 캐시로 옮긴다. 세션 시작 훅이 부르고 **끝나기를 기다린다**.
#
# 이 스크립트는 **표시 여부를 판단하지 않는다.** 무엇을 띄울지는 세션 시작 훅이 캐시를 읽고
# 정하고, 여기는 "원본 → 로컬 캐시" 이관과 실패 흡수만 맡는다. 그 경계 덕에 갱신 방식이
# 바뀌어도(개인 훅 시절의 인증 gh, 공개 뒤의 인증 없는 curl) 표시 계층은 영향권 밖이다.
#
# 모든 실패는 무음이다 — 오프라인·요청 수 제한·깨진 응답 어느 쪽이든 기존 캐시를 그대로 두고
# 조용히 끝낸다. 갱신이 늦는 것은 "안 뜸" 으로 나타날 뿐 세션을 방해하지 않는다.
#
# **훅이 기다리므로 여기 걸리는 시간이 곧 세션 시작 지연이다.** 그 상한은 이 스크립트가 아니라
# 훅 등록의 `timeout` 이 걸고, 빈도는 아래 쿨다운이 정한다 — 신선하면 네트워크로 안 나간다.
# 진단은 RELEASE_HERALD_DEBUG=1 로 켠다.
#
#   수동 실행: ./hooks/update-cache.sh [--force]
#     --force  쿨다운과 조건부 요청(ETag)을 건너뛰고 즉시 전체를 받는다 (진단·초기 설치용)

set -u

CACHE="${RELEASE_HERALD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/release-herald/summaries.json}"
STATE_DIR="${RELEASE_HERALD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/release-herald}"
STAMP="$STATE_DIR/last-update"
LOCK="$STATE_DIR/update.lock"
ETAG_FILE="$STATE_DIR/etag"   # 캐시와 짝인 원본의 ETag

# 세션을 켤 때마다 네트워크로 나가지 않도록 최소 간격을 둔다. **생성 주기보다 짧게 둔다** —
# 길면 생성된 요약을 캐시가 건너뛰어, 워크플로를 촘촘히 해도 여기가 새 병목이 된다.
# 생성이 3시간마다(summarize.yml)이므로 그 1/3 이다.
COOLDOWN="${RELEASE_HERALD_COOLDOWN:-3600}"   # 1시간

# 캐시에 남길 릴리스 개수. **훅의 비용은 파일 크기가 아니라 한 번에 조립하는 미통지 릴리스
# 개수에 비례한다** — 11개를 담으면 최대 밀림 경로가 세션 시작 예산을 넘었고 8개면 절반으로
# 떨어졌다. 요약 원본은 공식 릴리스 피드(최근 10개)보다 넓게 누적해야 하지만 훅이 읽는 캐시는
# 그럴 이유가 없다.
KEEP="${RELEASE_HERALD_CACHE_KEEP:-8}"

REPO="${RELEASE_HERALD_REPO:-myalim/release-herald}"
# 공개 저장소의 raw 경로에서 인증 없이 받는다 — 설치한 사람에게 `gh` 로그인을 요구하지 않기 위해서다.
# raw 는 ETag·304 를 지원하고(조건부 요청이 그대로 선다) CDN 캐시가 5분이다. 인증 없는 요청에는
# 요청자(IP) 단위 횟수 제한이 걸리지만 쿨다운이 사용자당 시간 1회로 묶는다 — 걸려도 실패는 무음이다.
# 서빙 위치가 바뀌면 이 URL 한 줄만 바뀐다.
REF="${RELEASE_HERALD_REF:-main}"
SRC_PATH="${RELEASE_HERALD_SRC_PATH:-data/summaries.json}"
SRC_URL="https://raw.githubusercontent.com/$REPO/$REF/$SRC_PATH"

dbg() { [ -n "${RELEASE_HERALD_DEBUG:-}" ] && printf '[release-herald/update] %s\n' "$*" >&2; return 0; }

FORCE=""
[ "${1:-}" = "--force" ] && FORCE=1

command -v jq >/dev/null 2>&1 || { dbg "jq 없음"; exit 0; }
command -v curl >/dev/null 2>&1 || { dbg "curl 없음"; exit 0; }

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
RESP="$CACHE.resp.$$"
TMP="$CACHE.fetch.$$"
TRIM="$CACHE.trim.$$"
trap 'rm -f "$RESP" "$TMP" "$TRIM" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' EXIT

# 쓰다 잘려도 반쪽 파일이 남지 않게 임시 파일에 쓰고 rename 한다.
atomic_write() { printf '%s\n' "$2" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1" 2>/dev/null; }
# 캐시 계약 — 조건부 요청 여부와 받은 내용 검증이 같은 식을 써야 둘이 어긋나지 않는다.
CONTRACT='.schema == 1 and (.releases | type) == "array"'

# 조건부 요청 — 직전 응답의 ETag 를 보내 원본이 그대로면 304 로 본문 없이 끝낸다. 원본은 누적
# 파일이라 릴리스마다 커지는데 갱신 대부분은 바뀐 게 없는 회차라, 그 전송을 건너뛴다.
# **ETag 는 캐시와 짝이라 캐시가 계약대로 읽힐 때만 보낸다** — 캐시가 없거나 깨졌는데 ETag 만
# 보내면 304 가 돌아와 영영 다시 받지 못한다. --force 는 진단·설정 변경(보관 개수 등) 뒤에
# 다시 받으려는 것이라 조건 없이 받는다.
COND=()
if [ -z "$FORCE" ] && [ -s "$ETAG_FILE" ] \
   && jq -e "$CONTRACT" "$CACHE" >/dev/null 2>&1; then
  read -r PREV_ETAG < "$ETAG_FILE"
  [ -n "$PREV_ETAG" ] && COND=(-H "If-None-Match: $PREV_ETAG")
fi

# -i 로 헤더째 받는다. curl 은 4xx·5xx 에도 0 으로 끝나 종료코드로는 갈리지 않아 상태 줄로 가른다.
# 프록시의 CONNECT 응답이 상태 줄을 가로채지 않게 빼고 받는다. 시간 상한은 훅 등록의 timeout(3초)보다
# 짧게 걸어, 네트워크가 멈춰도 이 스크립트가 먼저 끝나 정리(락·임시 파일)를 마친다.
curl -sS -i --suppress-connect-headers --connect-timeout 1 --max-time 2 ${COND[@]+"${COND[@]}"} \
   "$SRC_URL" > "$RESP" 2>/dev/null
STATUS=""
[ -s "$RESP" ] && read -r _ STATUS _ < "$RESP"
STATUS="${STATUS%$'\r'}"

if [ "$STATUS" = "304" ]; then
  # 안 바뀌었다는 확인도 신선함이다 — 쿨다운을 다시 세지 않으면 다음 세션이 또 묻는다.
  atomic_write "$STAMP" "$NOW"
  dbg "변경 없음 (304) — 캐시 유지"
  exit 0
fi
if [ "$STATUS" != "200" ]; then
  dbg "받기 실패 (오프라인·요청 수 제한·경로 없음 · 상태 ${STATUS:-없음})"
  exit 0
fi

# 첫 빈 줄 뒤가 본문이다. ETag 는 따옴표째 다음 요청에 그대로 돌려준다 — 헤더 이름은 대소문자가
# 갈리므로(실제 응답은 `Etag`) 소문자로 맞춰 찾는다.
awk 'f { print; next } /^\r?$/ { f = 1 }' "$RESP" > "$TMP" 2>/dev/null
NEW_ETAG=$(awk '/^\r?$/ { exit } tolower($0) ~ /^etag:/ { sub(/^[^:]*:[ \t]*/, ""); sub(/\r$/, ""); print; exit }' "$RESP" 2>/dev/null)

# ── 검증 ────────────────────────────────────────────────────────────
# 받은 것이 요약 파일이 맞는지 본다. 프록시나 로그인 페이지가 200 으로 HTML 을 주는 경우까지 막으려면
# 내용을 봐야 한다. **깨진 것을 캐시에 넣는 것이 안 받는 것보다 나쁘다** — 훅은 캐시를
# 신뢰하고 읽는다.
if ! jq -e "$CONTRACT" "$TMP" >/dev/null 2>&1; then
  dbg "받은 내용이 계약과 다름 — 캐시 유지"
  exit 0
fi

# ── 자르기 + 원자적 교체 ────────────────────────────────────────────
if ! jq --argjson keep "$KEEP" '.releases = .releases[0:$keep]' "$TMP" > "$TRIM" 2>/dev/null; then
  dbg "자르기 실패"
  exit 0
fi

# ETag 는 교체 **앞에서 지우고 뒤에서만** 적는다 — 그 사이에 실패하거나 훅 timeout 에 잘려도
# 어긋난 짝(옛 캐시+새 ETag · 새 캐시+옛 ETag)이 남지 않고, 지운 채 끝나면 다음 회차가 조건 없이
# 받을 뿐이다. 헤더가 없는 응답도 지운 채 둔다.
rm -f "$ETAG_FILE" 2>/dev/null
if mv -f "$TRIM" "$CACHE" 2>/dev/null; then
  atomic_write "$STAMP" "$NOW"
  if [ -n "$NEW_ETAG" ]; then
    atomic_write "$ETAG_FILE" "$NEW_ETAG"
  fi
  # 진단이 꺼져 있으면 개수 세기(jq 한 번)를 건너뛴다 — 명령 치환은 dbg 가 버려도 실행된다.
  [ -n "${RELEASE_HERALD_DEBUG:-}" ] && dbg "갱신 완료: $(jq -r '.releases | length' "$CACHE" 2>/dev/null)개 릴리스 (원본 ref=$REF)"
else
  dbg "교체 실패"
fi
exit 0
