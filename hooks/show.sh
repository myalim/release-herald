#!/usr/bin/env bash
# 지난 릴리스 요약을 골라 본다 — 세션 시작 화면이 놓친 것을 오너가 직접 확인하는 경로.
#
# 표시 계층의 두 번째 진입점이다. session-start.sh 가 **밀어주는** 쪽이라면 여기는
# **당겨오는** 쪽이고, 같은 캐시·같은 필드(`impact`·`weight`)를 읽는다.
#
# **게이트를 걸지 않는 것이 이 도구의 존재 이유다** — 화면(`weight 1`)에서 잘린 것을 보러
# 오는 경로라, 여기서도 1 만 보이면 아무 소용이 없다. 1 을 위에 놓고 나머지를 아래에 둔다.
#
# 훅과 달리 실패가 침묵이 아니다 — 사람이 직접 부른 명령이라 왜 안 나왔는지 말해야 한다.
#
#   ./hooks/show.sh                 릴리스 목록
#   ./hooks/show.sh 260             한 릴리스 (v2.1.260 · 2.1.260 · 260 다 된다)
#   ./hooks/show.sh 257..263        범위 (양끝 포함)
#   ./hooks/show.sh --all 260       impact:internal 까지
#   ./hooks/show.sh --en 260        원문(en) 병기

set -u

# 캐시가 정본이다 — 플러그인으로 나가면 저장소가 없다. 못 읽을 때만 옆의 원본으로 내려간다.
CACHE="${RELEASE_HERALD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/release-herald/summaries.json}"
STATE="${RELEASE_HERALD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/release-herald/notified}"
FALLBACK="${0%/*}/../data/summaries.json"

usage() {
  cat <<'USAGE'
지난 릴리스 요약을 골라 본다.

  show.sh                 릴리스 목록
  show.sh 260             한 릴리스 (v2.1.260 · 2.1.260 · 260 다 된다)
  show.sh 257..263        범위 (양끝 포함)

옵션
  --all   impact:internal 항목까지 (기본은 user 만)
  --en    원문(en) 병기 — ko 는 80자 상한이라 식별자가 잘린다
USAGE
}

command -v jq >/dev/null 2>&1 || { echo "jq 가 필요합니다." >&2; exit 1; }

ALL=false
EN=false
TARGET=""
for a in "$@"; do
  case "$a" in
    --all)     ALL=true ;;
    --en)      EN=true ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "모르는 옵션: $a" >&2; usage >&2; exit 2 ;;
    *)         TARGET="$a" ;;
  esac
done

if [ -r "$CACHE" ]; then
  DATA="$CACHE"
elif [ -r "$FALLBACK" ]; then
  DATA="$FALLBACK"
else
  echo "요약 데이터가 없습니다 — 캐시도 원본도 못 읽었습니다." >&2
  echo "  캐시: $CACHE" >&2
  echo "  받기: ${0%/*}/update-cache.sh --force" >&2
  exit 1
fi

# 어디까지 통지됐는지 표시하려고 읽는다. **통지 = 화면에 떴다가 아니다** — weight 1 이
# 0건인 릴리스는 통지되고도 화면이 비므로, 목록에 두 값을 나란히 두고 판단은 사람이 한다.
LAST=""
[ -r "$STATE" ] && read -r LAST < "$STATE"
LAST="${LAST//[[:space:]]/}"

# ── 목록 ────────────────────────────────────────────────────────────
if [ -z "$TARGET" ]; then
  jq -r --arg last "$LAST" --arg src "$DATA" '
    .releases as $r
    | "요약 \($r|length)개 — \($src)",
      "",
      ( $r[]
        | ([.items[] | select(.impact == "user")] | length) as $u
        | ([.items[] | select(.impact == "user" and .weight == 1)] | length) as $w
        | "  " + ((.version + "           ")[0:11])
          + .date
          + "   user \($u) · 화면 \($w)"
          + (if .version == $last then "   ← 여기까지 통지됨" else "" end)
      ),
      "",
      "  화면 0 = 세션 시작에 아무것도 안 떴다 (통지 자체는 됐을 수 있다)."
  ' "$DATA"
  exit 0
fi

# ── 대상 확정 ───────────────────────────────────────────────────────
case "$TARGET" in
  *..*) FROM="${TARGET%%..*}"; TO="${TARGET##*..}" ;;
  *)    FROM="$TARGET";        TO="$TARGET" ;;
esac

# 버전 대소 비교를 하지 않는다 — session-start.sh 와 같은 이유로, 문자열 비교는
# v2.1.9 > v2.1.10 이 되는 함정이 있다. 배열이 최신 우선이라 **인덱스**로 자른다.
for q in "$FROM" "$TO"; do
  if ! jq -e --arg q "$q" '
        any(.releases[];
            .version == $q or .version == ("v" + $q) or (.version | endswith("." + $q)))
      ' "$DATA" >/dev/null 2>&1; then
    echo "'$q' 에 해당하는 릴리스가 데이터에 없습니다." >&2
    echo "  목록: ${0##*/} (인자 없이)" >&2
    exit 1
  fi
done

jq -r --arg from "$FROM" --arg to "$TO" --argjson all "$ALL" --argjson en "$EN" '
  def idx($r; $q):
    [range(0; $r|length)
     | select($r[.].version == $q
              or $r[.].version == ("v" + $q)
              or ($r[.].version | endswith("." + $q)))]
    | first;

  # 항목 한 줄. --en 이면 원문을 들여써 붙인다 — ko 가 80자 상한이라 환경변수명·설정 키가
  # 잘리고, 그때 필요한 것이 원문이다.
  def line($it; $tag):
    "   · " + $tag + $it.ko + (if $en then "\n       " + $it.en else "" end);

  .releases as $r
  | idx($r; $from) as $a
  | idx($r; $to) as $b
  | ([$a, $b] | min) as $lo
  | ([$a, $b] | max) as $hi
  | $r[$lo : $hi + 1][]
  | . as $rel
  | ( [ "## \($rel.version)   \($rel.date)", "   \($rel.url)", "" ]

      + ( [$rel.items[] | select(.impact == "user" and .weight == 1)] as $w1
          | if ($w1 | length) == 0
            then [ "  화면 대상 (weight 1) — 없음" ]
            else [ "  화면 대상 (weight 1)" ] + [ $w1[] | line(.; "") ]
            end )
      + [ "" ]

      + ( [$rel.items[] | select(.impact == "user" and .weight != 1)]
          | sort_by(.weight) as $rest
          | if ($rest | length) == 0 then []
            else [ "  그 밖의 user 항목" ]
                 + [ $rest[] | line(.; "[w\(.weight)] ") ] + [ "" ]
            end )

      + ( if $all then
            ( [$rel.items[] | select(.impact == "internal")] | sort_by(.weight) as $int
              | if ($int | length) == 0 then []
                else [ "  internal" ]
                     + [ $int[] | line(.; "[w\(.weight)] ") ] + [ "" ]
                end )
          else [] end )
    )[]
' "$DATA"
