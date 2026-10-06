#!/usr/bin/env bash
# 지난 릴리스 요약을 골라 본다 — 세션 시작 화면이 놓친 것을 사용자가 직접 확인하는 경로.
# 사용법은 --help.
#
# **게이트를 걸지 않는 것이 이 도구의 존재 이유다** — 화면(`weight 1`)에서 잘린 것을 보러
# 오는 경로라, 여기서도 1 만 보이면 아무 소용이 없다.
#
# 훅과 달리 실패가 침묵이 아니다 — 사람이 직접 부른 명령이라 왜 안 나왔는지 말해야 한다.

set -u

# 캐시가 정본이다 — 플러그인에 실린 data/ 는 설치·업데이트 시점의 사본이라 최신이 아니다. 다만
# 캐시는 최신 몇 개만 담으므로(update-cache.sh 의 KEEP) 캐시에 없는 오래된 릴리스는 그 사본에서 채운다.
CACHE="${RELEASE_HERALD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/release-herald/summaries.json}"
STATE="${RELEASE_HERALD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/release-herald/notified}"
FALLBACK="${0%/*}/../data/summaries.json"
# 목록 모드가 보이는 릴리스 수 — --help 문구와 test-show.sh 가 같은 값을 적는다.
LIST_MAX=10

usage() {
  cat <<'USAGE'
지난 Claude Code 릴리스 요약을 봅니다.

  /release-herald:show                     릴리스 목록 (최신 10개 — 이전 것은 찾기나 버전으로 봅니다)
  /release-herald:show 260                 한 릴리스 (v2.1.260 · 2.1.260 · 260 모두 됩니다)
  /release-herald:show 257..263            여러 릴리스 (양끝 포함)
  /release-herald:show --find 권한 확인    낱말이 모두 든 변경을 최신부터 (요약과 원문, 대소문자 무시)
  /release-herald:show --area hooks        그 영역의 변경을 최신부터

  --find 와 --area 를 함께 쓰면 둘 다 맞는 변경만, 버전을 주면 그 안에서만 찾습니다.

옵션
  --all   내부 변경까지 함께
  --en    원문(영어)도 함께 — 요약에서 잘린 옵션 이름을 확인할 때
USAGE
}

command -v jq >/dev/null 2>&1 || { echo "jq 가 필요합니다." >&2; exit 1; }

ALL=false
EN=false
TARGET=""
FIND=""
AREA=""
# 값을 받는 옵션은 다음 토큰을 그대로 값으로 받는다(getopt 관례) — 찾기 낱말이 `--resume` 같은
# 플래그 이름일 수 있다. 영역 자리에 옵션이 잘못 들어오면 아래 영역 확인이 막는다. 공백만 준 값도
# 빠진 값으로 본다 — 찾기 낱말이 0개면 모든 항목이 맞는다.
need_value() { [ $# -ge 2 ] && [ -n "${2//[[:space:]]/}" ] && return 0; echo "$1 에는 값이 필요합니다." >&2; exit 2; }
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --all)     ALL=true ;;
    --en)      EN=true ;;
    --find)    need_value "$@"; FIND="$2"; shift ;;
    --area)    need_value "$@"; AREA="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "모르는 옵션입니다: $a" >&2; usage >&2; exit 2 ;;
    # 대상을 둘 이상 주면 앞의 것이 조용히 사라진다 — 모르는 옵션과 같게 막는다(범위는 `..`).
    *)         [ -n "$TARGET" ] && { echo "버전은 하나만 지정합니다. 여러 릴리스는 257..263 처럼 씁니다." >&2; exit 2; }
               TARGET="$a" ;;
  esac
  shift
done

# 소스마다 읽히고 계약 모양인지 먼저 가린다 — 깨진 캐시를 고르면 원본이 답할 것도 "없다" 로
# 나오거나 jq 오류로 끝난다.
usable() { [ -r "$1" ] && jq -e '.releases | type == "array"' "$1" >/dev/null 2>&1; }
SOURCES=()
usable "$CACHE" && SOURCES+=("$CACHE")
usable "$FALLBACK" && SOURCES+=("$FALLBACK")

case ${#SOURCES[@]} in
  2)
    # 같은 버전은 캐시 쪽을 쓴다(원본보다 늦게 받았을 수 있다). 순서는 생성 계약과 같은 키
    # (날짜, 버전 정수열)로 다시 세운다 — 캐시가 원본보다 새 릴리스를 가질 수 있어 이어 붙이기만
    # 하면 최신 우선이 깨지고, 아래 범위 자르기가 그 순서를 딛는다.
    DATA="$(mktemp)"
    trap 'rm -f "$DATA"' EXIT
    jq -s '
      .[0] + {releases: (
        ([.[0].releases[].version]) as $have
        | (.[0].releases + [.[1].releases[] | select(.version as $v | $have | index($v) | not)])
        | sort_by([.date, (.version | [scan("[0-9]+") | tonumber])]) | reverse )}
    ' "$CACHE" "$FALLBACK" > "$DATA" ;;
  1)
    DATA="${SOURCES[0]}" ;;
  *)
    echo "요약을 읽지 못했습니다. 잠시 뒤 새 세션을 열면 다시 받습니다." >&2
    if [ -n "${RELEASE_HERALD_DEBUG:-}" ]; then
      echo "  캐시: $CACHE" >&2
      echo "  받기: ${0%/*}/update-cache.sh --force" >&2
    fi
    exit 1 ;;
esac

# **통지 = 화면에 떴다가 아니다** — 화면 판정은 릴리스가 아니라 함께 밀린 묶음 단위다. 묶음 전체에
# `weight 1` 이 없으면 참고 한 줄이나 안내만 뜨고, 묶음의 다른 버전에 `weight 1` 이 있으면
# 이 릴리스의 항목은 화면에 오르지 않는다. 묶음에 체감 항목이 아예 없으면 화면이 빈다.
# 그래서 목록은 두 값을 나란히 두기만 한다.
LAST=""
[ -r "$STATE" ] && read -r LAST < "$STATE"
LAST="${LAST//[[:space:]]/}"

# 버전 지정 해석과 범위 자르기 — 확인·찾기·출력이 같은 규칙을 쓰도록 한 곳에 둔다.
# 버전 대소 비교를 하지 않는다 — 문자열 비교가 v2.1.9 > v2.1.10 이 되는 함정은
# session-start.sh 가 갖는다. 배열이 최신 우선이라 **인덱스**로 자른다.
# shellcheck disable=SC2016  # jq 프로그램이라 \$ 는 jq 변수다
JQ_DEFS='
  def ver_is($q): .version == $q or .version == ("v" + $q) or (.version | endswith("." + $q));
  def idx($q): . as $r | [range(0; length) | select($r[.] | ver_is($q))] | first;
  def pick($from; $to):
    if $from == "" then .[]
    else idx($from) as $a | idx($to) as $b | .[([$a, $b] | min) : ([$a, $b] | max) + 1][] end;
  def pad: (. + "           ")[0:11];
'

# ── 목록 ────────────────────────────────────────────────────────────
if [ -z "$TARGET" ] && [ -z "$FIND" ] && [ -z "$AREA" ]; then
  # 목록은 최신 LIST_MAX 개만 보인다 — 릴리스가 쌓일수록 목록이 화면을 채워 정작 최근 것이 밀린다.
  # 생략분은 찾기와 한 릴리스 조회로 보게 안내한다(범위로 안내하면 출력이 너무 길다). 자르기는 배열 위치로 한다.
  jq -r --arg last "$LAST" --argjson max "$LIST_MAX" "$JQ_DEFS"'
    # 안내 명령에 쓸 짧은 버전 — 끝자리가 더 최신의 다른 릴리스와 겹치면(마이너가 바뀐 뒤)
    # 조회가 그쪽을 집으므로 v 를 뗀 전체 버전으로 쓴다.
    def short($i): (.[$i].version | split(".")[-1]) as $t
      | if idx($t) == $i then $t else (.[$i].version | ltrimstr("v")) end;
    .releases as $r
    | ($r[0:$max]) as $shown
    | ($r[$max:]) as $hidden
    | (if ($hidden | length) == 0 then "릴리스 \($r|length)개 · 최신순"
       else "릴리스 \($r|length)개 중 최신 \($shown|length)개 · 최신순" end),
      "",
      ( $shown[]
        | ([.items[] | select(.impact == "user")] | length) as $u
        | ([.items[] | select(.impact == "user" and .weight == 1)] | length) as $w
        | "  " + (.version | pad)
          + .date
          + "   주요 \($w) / 전체 \($u)"
          + (if .version == $last then "   ← 마지막으로 알린 버전" else "" end)
      ),
      ( if ($hidden | length) == 0 then empty
        else "",
             "  이전 릴리스 \($hidden|length)개는 생략했습니다 · 찾기: /release-herald:show --find 낱말 · 한 릴리스: /release-herald:show \($r | short($max))",
             # 마지막으로 알린 버전이 생략 구간에 있으면 본문에 마커가 없다 — 그 사실을 따로 밝힌다.
             ( [$hidden[] | select(.version == $last)] | first
               | if . == null then empty
                 else "  마지막으로 알린 버전(\(.version))은 생략된 구간에 있습니다" end )
        end ),
      "",
      "  주요: 세션 시작 화면에서 알리는 변경 · 전체: 사용자에게 의미 있는 변경 전부",
      # 릴리스가 0개면 가리킬 버전이 없다 — 이 줄을 빼야 jq 가 오류로 멈추지 않는다.
      ( if ($r | length) == 0 then empty
        elif ($hidden | length) > 0 then "  자세히: /release-herald:show \($r | short(0))"
        else "  자세히: /release-herald:show \($r | short(0)) · 찾기: /release-herald:show --find 낱말" end )
  ' "$DATA"
  exit 0
fi

# ── 대상 확정 ───────────────────────────────────────────────────────
# 버전을 안 주면(찾기만) FROM 이 비어 pick 이 전 범위를 낸다.
case "$TARGET" in
  *..*) FROM="${TARGET%%..*}"; TO="${TARGET##*..}" ;;
  *)    FROM="$TARGET";        TO="$TARGET" ;;
esac

if [ -n "$FROM" ]; then
  MISSING="$(jq -r --arg from "$FROM" --arg to "$TO" "$JQ_DEFS"'
    .releases as $r | [$from, $to] | unique[] | select(. as $q | $r | idx($q) == null)
  ' "$DATA" | head -1)"
  if [ -n "$MISSING" ]; then
    echo "'$MISSING' 에 해당하는 릴리스 요약이 없습니다. 목록은 /release-herald:show 로 봅니다." >&2
    exit 1
  fi
fi

# ── 찾기 ────────────────────────────────────────────────────────────
# 릴리스별 화면 구분(weight 1 / 그 밖)을 버리고 맞는 항목만 한 줄씩 낸다 — 묻는 것이
# "언제 바뀌었나" 라 버전이 줄마다 붙어야 한다.
if [ -n "$FIND" ] || [ -n "$AREA" ]; then
  # 영역 목록은 데이터에서 읽는다 — 배포본에는 스키마가 따라가지 않는다. 오타가 "0건" 으로
  # 끝나면 그 영역에 변경이 없었다는 뜻과 구분되지 않아 먼저 막는다.
  if [ -n "$AREA" ]; then
    AREAS="$(jq -r '[.releases[].items[].area[]?] | unique[]' "$DATA")"
    if ! grep -qxF -- "$AREA" <<<"$AREAS"; then
      echo "'$AREA' 영역이 없습니다." >&2
      echo "  있는 영역: $(paste -sd' ' - <<<"$AREAS")" >&2
      exit 2
    fi
  fi
  OUT="$(jq -r --arg from "$FROM" --arg to "$TO" --argjson all "$ALL" --argjson en "$EN" \
              --arg find "$FIND" --arg area "$AREA" "$JQ_DEFS"'
    # 낱말은 공백으로 나눠 전부 들어야 맞는다 — 순서와 붙어 있는지는 묻지 않는다.
    ($find | ascii_downcase | [splits("\\s+")] | map(select(length > 0))) as $words
    | .releases | pick($from; $to)
    | . as $rel
    | .items[]
    | select($all or .impact == "user")
    | select($area == "" or ((.area // []) | index($area)))
    | ((.ko + " " + .en) | ascii_downcase) as $text
    | select(all($words[]; . as $w | $text | contains($w)))
    | "  " + ($rel.version | pad)
      + "[" + ((.area // ["영역 없음"]) | join(","))
      + (if .impact == "internal" then " · 내부" else "" end) + "] "
      + .ko + (if $en then "\n" + (" " * 13) + .en else "" end)
  ' "$DATA")"
  if [ -z "$OUT" ]; then
    echo "맞는 변경이 없습니다${FIND:+ (낱말: $FIND)}${AREA:+ (영역: $AREA)}." >&2
    $ALL || echo "  내부 변경까지 찾으려면 --all 을 붙입니다." >&2
    exit 1
  fi
  printf '%s\n' "$OUT"
  exit 0
fi

jq -r --arg from "$FROM" --arg to "$TO" --argjson all "$ALL" --argjson en "$EN" "$JQ_DEFS"'

  def line($it; $tag):
    "   · " + $tag + $it.ko + (if $en then "\n       " + $it.en else "" end);

  .releases | pick($from; $to)
  | . as $rel
  | ( [ "\($rel.version) · \($rel.date)", "\($rel.url)", "" ]

      + ( [$rel.items[] | select(.impact == "user" and .weight == 1)] as $w1
          | if ($w1 | length) == 0
            then [ "  주요 변경 없음" ]
            else [ "  주요 변경" ] + [ $w1[] | line(.; "") ]
            end )
      + [ "" ]

      + ( [$rel.items[] | select(.impact == "user" and .weight != 1)]
          | sort_by(.weight) as $rest
          | if ($rest | length) == 0 then []
            else [ "  그 밖의 변경" ]
                 + [ $rest[] | line(.; "") ] + [ "" ]
            end )

      + ( if $all then
            ( [$rel.items[] | select(.impact == "internal")] | sort_by(.weight) as $int
              | if ($int | length) == 0 then []
                else [ "  내부 변경" ]
                     + [ $int[] | line(.; "") ] + [ "" ]
                end )
          else [] end )
    )[]
' "$DATA"
