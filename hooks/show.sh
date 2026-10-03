#!/usr/bin/env bash
# 지난 릴리스 요약을 골라 본다 — 세션 시작 화면이 놓친 것을 오너가 직접 확인하는 경로.
# 사용법은 --help.
#
# **게이트를 걸지 않는 것이 이 도구의 존재 이유다** — 화면(`weight 1`)에서 잘린 것을 보러
# 오는 경로라, 여기서도 1 만 보이면 아무 소용이 없다.
#
# 훅과 달리 실패가 침묵이 아니다 — 사람이 직접 부른 명령이라 왜 안 나왔는지 말해야 한다.

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
    # 대상을 둘 이상 주면 앞의 것이 조용히 사라진다 — 모르는 옵션과 같게 막는다(범위는 `..`).
    *)         [ -n "$TARGET" ] && { echo "대상은 하나만 지정합니다 — 범위는 257..263" >&2; exit 2; }
               TARGET="$a" ;;
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

# **통지 = 화면에 떴다가 아니다** — 화면 판정은 릴리스가 아니라 함께 밀린 묶음 단위다. 묶음 전체에
# `weight 1` 이 없으면 참고 한 줄이나 안내만 뜨고, 묶음의 다른 버전에 `weight 1` 이 있으면
# 이 릴리스의 항목은 화면에 오르지 않는다. 묶음에 체감 항목이 아예 없으면 화면이 빈다.
# 그래서 목록은 두 값을 나란히 두기만 한다.
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
      "  화면 0 = weight 1 이 없는 릴리스 — 함께 밀린 버전에도 없으면 참고 한 줄이나 안내만 뜬다 (user 0 이면 침묵)."
  ' "$DATA"
  exit 0
fi

# ── 대상 확정 ───────────────────────────────────────────────────────
case "$TARGET" in
  *..*) FROM="${TARGET%%..*}"; TO="${TARGET##*..}" ;;
  *)    FROM="$TARGET";        TO="$TARGET" ;;
esac

# 버전 대소 비교를 하지 않는다 — 문자열 비교가 v2.1.9 > v2.1.10 이 되는 함정은
# session-start.sh 가 갖는다. 배열이 최신 우선이라 **인덱스**로 자른다.
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
