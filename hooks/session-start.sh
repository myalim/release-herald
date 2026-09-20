#!/usr/bin/env bash
# SessionStart 훅 — Claude Code 의 새 릴리스를 세션 시작 화면에 한국어로 띄운다.
#
# 두 수신자에게 다른 계약을 낸다 — 화면은 사용자, 컨텍스트는 Claude 다.
# **컨텍스트가 화면의 상위집합인 것이 계약이다** — 그래야 화면에서 잘린 항목을 물어도 답한다.
#
# **모든 실패 경로의 종착지는 침묵이다.** SessionStart 는 세션 시작을 블록할 수 없으므로
# "실패했으니 멈춘다" 는 선택지가 애초에 없고, 알 수 없는 데이터로 화면을 어지럽히는 것보다
# 안 뜨는 편이 낫다. 그래서 진단 경로를 함께 둔다(RELEASE_HERALD_DEBUG) — 그것 없이는
# "안 뜨는 게 정상 침묵인지 고장인지" 를 가릴 수단이 없어 개발 중 디버깅이 불가능해진다.
#
# 등록 (~/.claude/settings.json) — matcher 는 startup|clear 다.
# resume·compact 에서 다시 뜨면 같은 릴리스를 하루에 몇 번씩 보게 된다:
#   {
#     "hooks": {
#       "SessionStart": [
#         { "matcher": "startup|clear",
#           "hooks": [{ "type": "command", "timeout": 3,
#                       "command": "/절대경로/release-herald/hooks/session-start.sh" }] }
#       ]
#     }
#   }

# 캐시와 통지 기록은 성격이 다르므로 자리를 나눈다 — 캐시는 지워져도 다음 갱신에 복구되지만,
# 통지 기록이 지워지면 과거 릴리스가 다시 쏟아진다. 둘 다 **저장소 밖**에 둔다: 코드와 같은
# 자리에 두면 P3 에서 플러그인으로 옮길 때 이력이 끊긴다.
CACHE="${RELEASE_HERALD_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/release-herald/summaries.json}"
STATE="${RELEASE_HERALD_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/release-herald/notified}"

# 통지 기록이 캐시의 보관 범위보다 오래됐을 때 취할 개수. 전부를 미통지로 보면 최초 설치와
# 같은 사고가 되므로 최근 몇 개만 취한다.
FRESH_LIMIT="${RELEASE_HERALD_FRESH_LIMIT:-3}"

# 화면 줄 수 상한. 단일 릴리스에서는 weight:1 이 자연 수렴해 상한이 필요 없었지만(실측 10개
# 중 9개가 8줄 이하), **여러 버전이 밀리면 그 수렴이 합산으로 깨진다** — 릴리스당 평균 3.2개라
# 9개가 밀리면 33줄이 된다. 그래서 상한은 단일 릴리스 경로를 거의 건드리지 않으면서 합산만
# 자르는 자리에 둔다. 잘린 것은 컨텍스트에 그대로 있어 물어보면 답한다.
MAX_LINES="${RELEASE_HERALD_MAX_LINES:-8}"

# 진단 경로. 판정이 어디서 멈췄는지만 stderr 로 낸다 — stdout 은 훅 프로토콜이 쓰므로 건드리지 않는다.
dbg() { [ -n "$RELEASE_HERALD_DEBUG" ] && printf '[release-herald] %s\n' "$*" >&2; return 0; }

command -v jq >/dev/null 2>&1 || { dbg "jq 없음 — 침묵"; exit 0; }

# ── 캐시 갱신을 기다린다 ────────────────────────────────────────────
# **기다리지 않으면 이번 세션은 갱신 전 캐시로 판정한다** — 새 릴리스가 늘 한 세션 늦게 뜬다.
# 그 지연을 뒤에서 메우려면 통지를 배너 밖(프롬프트 사이)으로 옮겨야 하는데, 거기서는 응답에
# 밀려 놓치면서 **통지 기록은 소진된다** — 놓칠 수 있는 자리에 뜨는데 소진이 확정적이라
# 실사용에서 되돌렸다. 배너가 통지의 자리인 이상 갱신은 그 앞에 와야 한다.
#
# **대기를 감당할 수 있는 것은 쿨다운 때문이다** — 캐시가 신선하면 갱신기가 네트워크로 나가지
# 않고 즉시 끝나므로, 실제로 기다리는 것은 쿨다운이 풀린 첫 세션뿐이다(실측 0.6초, 그중 2/3 이
# GitHub API 응답 시간이라 줄일 여지가 없다).
#
# **상한은 훅 설정의 `timeout` 이 건다**(위 등록 예시) — 초과하면 하네스가 훅을 취소하고 출력을
# 버리므로 결과는 침묵이다. 여기서 타임아웃을 구현하지 않는 것은 bash 3.2 로 그것을 하려면
# 폴링 `sleep` 이 포크를 무더기로 무는데, 하네스가 이미 같은 일을 하기 때문이다.
UPDATER="${RELEASE_HERALD_UPDATER:-${0%/*}/update-cache.sh}"
if [ -z "${RELEASE_HERALD_NO_UPDATE:-}" ] && [ -x "$UPDATER" ]; then
  "$UPDATER" >/dev/null 2>&1
  dbg "갱신 완료: $UPDATER"
fi

[ -r "$CACHE" ] || { dbg "캐시 없음/읽기 불가: $CACHE"; exit 0; }

# 기록은 한 줄짜리 버전 문자열이다. 공백만 걷고 값 자체는 해석하지 않는다.
# **외부 명령 대신 bash 내장으로 읽는다** — 이 훅의 비용은 jq 가 아니라 프로세스 포크다
# (실측: jq 는 파싱·조립까지 15~19ms 인데 훅 전체는 76ms 였고, 차이가 전부 포크였다).
# 세션 시작 예산이 100ms 라 head·tr·sed 한 쌍씩이 그대로 예산을 먹는다.
LAST=""
# 존재 확인을 먼저 한다 — 입력 리다이렉션 실패는 셸 자신이 내는 에러라 뒤에 붙인
# 2>/dev/null 로는 막히지 않고, 최초 설치(기록 없음)에서 그 메시지가 그대로 샌다.
[ -r "$STATE" ] && read -r LAST < "$STATE"
LAST="${LAST//[[:space:]]/}"
dbg "캐시=$CACHE 기록=${LAST:-<없음>}"

# 판정과 분배를 jq 한 번으로 끝낸다. 원격에서 온 문자열은 여기서만 다뤄지고 셸 평가 경로에
# 들어가지 않는다 — 요약 문자열이 곧 명령이 되지 않도록.
#
# 출력은 세 줄이다: 1줄 = 상태, 2줄 = 새로 기록할 버전(없으면 빈 줄), 3줄 = 훅 출력 JSON(없으면 빈 줄).
#
# **상태 줄이 있는 이유는 침묵끼리 구분되지 않아서다.** 이 설계는 모든 실패가 침묵으로
# 수렴하는데, 정상 침묵(미통지분 없음)과 고장(계약 불일치)이 같은 빈 출력이면 진단이
# 거짓말을 한다 — 실제로 "미통지분 없음" 을 "캐시가 깨졌다" 로 보고한 적이 있고, 그것이
# 원인을 엉뚱한 곳에서 찾게 만들었다.
RESULT=$(jq -r --arg last "$LAST" --argjson fresh "$FRESH_LIMIT" --argjson max "$MAX_LINES" '
  # 스키마 가드 — 모르는 계약 버전이면 에러가 아니라 침묵이다.
  if (.schema != 1) then "SCHEMA", "", "" else

  .releases as $r
  # 마지막 통지 버전과 **문자열이 같은** 원소의 인덱스를 찾아 그 앞을 취한다.
  # 그래서 버전 대소 비교가 설계에서 사라진다 — v2.1.9 > v2.1.10 이 되어 통지가 조용히
  # 멈추는 함정이 성립할 자리가 없다.
  | ([range(0; $r|length) | select($r[.].version == $last)] | first) as $i
  | (
      # 기록이 아예 없다 = 최초 설치. 과거를 소급 통지하지 않고 기준선만 세운다.
      if ($last == "") then []
      # 기록은 있는데 캐시에 없다 = 통지가 파일의 보관 범위보다 오래됐다.
      elif ($i == null) then $r[0:$fresh]
      else $r[0:$i]
      end
    ) as $new

  | if ($new | length) == 0 then
      # 미통지분 없음. 기록은 최초 설치일 때만 세운다(기준선).
      if ($last == "" and ($r|length) > 0) then "BASE", $r[0].version, ""
      else "NONE", "", "" end
    else
      # impact:internal 은 여기서 걷힌다 — 양쪽 채널 어디에도 가지 않는다.
      [ $new[] | . as $rel | $rel.items[] | select(.impact == "user") | . + {v: $rel.version} ] as $user
      | [ $user[] | select(.weight == 1) ] as $shown
      | (
          if ($shown | length) == 0 then ""
          else
            # 여러 버전이 밀려도 버전별 블록을 쌓지 않고 하나로 합친다 — 화면 분량이
            # 1개 버전일 때와 같아야 한다. 헤더만 범위를 밝힌다.
            ( if ($new|length) == 1 then "Claude Code \($new[0].version)"
              else "Claude Code \($new[-1].version) → \($new[0].version) (\($new|length)개 버전)"
              end ) as $head
            # 최신 릴리스부터 채워 상한에서 자른다. $new 가 최신 우선이라 순서가 이미 그렇다.
            | ($shown | length) as $total
            | "[release-herald] \($head)\n"
              + ([ $shown[0:$max][] | "  · \(.ko)" ] | join("\n"))
              # 잘렸다는 사실을 숨기지 않는다 — 숨기면 "중요한 게 안 뜸" 과 구분되지 않는다.
              # 남은 것은 컨텍스트에 있으므로 물어보는 경로로 잇는다.
              + (if $total > $max then "\n  … 외 \($total - $max)건 — 물어보면 답합니다" else "" end)
              + "\n  \($new[0].url)"
          end
        ) as $sys

      # 컨텍스트는 화면의 상위집합이다. 원문(en)을 함께 싣는 것은 ko 가 80자 상한이라
      # 환경변수명·설정 키 같은 식별자가 잘리기 때문이다 — 잘리면 "그 환경변수 뭐였지" 에
      # 답할 수 없다.
      | ( "[release-herald] 마지막 통지 이후의 Claude Code 릴리스입니다 (최신 우선). "
          + "사용자 화면에는 이 중 일부만 떴으므로, 사용자가 못 본 항목을 물어도 여기서 답하세요.\n"
          + ([ $new[]
               | ( [ .items[] | select(.impact == "user")
                     | "- [\(.kind)] \(.ko)\n      \(.en)" ] ) as $lines
               | "\n## \(.version) (\(.date)) \(.url)\n"
                 # 빈 블록으로 두면 "볼 것이 없다" 와 "데이터가 없다" 가 구분되지 않는다.
                 # 두 빈 경우도 서로 다른 사실이라 나눈다 — 원문에 항목이 없던 릴리스가
                 # 실제로 있어서(스키마가 그 분포를 갖는다), "내부 변경뿐" 이라 단정하면
                 # Claude 가 없는 사실을 말하게 된다.
                 + (if ($lines | length) > 0 then ($lines | join("\n"))
                    elif (.items | length) == 0 then "- (원문에 항목 없음)"
                    else "- (사용자 체감 변경 없음 — 내부 변경뿐)" end)
             ] | join("\n"))
        ) as $ctx

      | ( { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: $ctx } }
          # systemMessage 는 비면 필드 자체를 넣지 않는다 — 빈 문자열은 빈 줄로 보인다.
          + (if $sys == "" then {} else { systemMessage: $sys } end)
        ) as $payload

      | "SHOW", $new[0].version, ($payload | @json)
    end
  end
' "$CACHE" 2>/dev/null)

# 출력이 아예 없으면 jq 가 죽은 것이다 — 캐시가 JSON 으로 파싱되지 않았다는 뜻이라
# 아래 상태 줄과 다른 사건이고, 그래서 여기서 먼저 가른다.
if [ -z "$RESULT" ]; then
  dbg "캐시를 읽지 못했다 (JSON 파싱 실패)"
  exit 0
fi

# 상태 / 새 기록 버전 / payload. 파라미터 확장으로 가른다(위와 같은 이유 — 포크를 늘리지 않는다).
STATUS="${RESULT%%$'\n'*}"
REST="${RESULT#*$'\n'}"
NEWVER="${REST%%$'\n'*}"
PAYLOAD="${REST#*$'\n'}"
# REST 에 개행이 없으면 위 두 확장이 같은 값을 준다 — 그때 없는 것은 payload 쪽이다.
# **NEWVER 에는 이 가드를 걸지 않는다** — 걸면 기준선만 세우는 경로에서 그 버전이 지워진다.
[ "$PAYLOAD" = "$REST" ] && PAYLOAD=""

case "$STATUS" in
  SCHEMA) dbg "계약 버전을 모른다 — 침묵"; exit 0 ;;
  NONE)   dbg "미통지분 없음 (기록=$LAST) — 정상 침묵"; exit 0 ;;
  BASE)   dbg "최초 설치 — 기준선을 $NEWVER 로 세우고 이번 세션은 침묵" ;;
  SHOW)   dbg "미통지분 있음 — $NEWVER 까지 통지" ;;
  *)      dbg "알 수 없는 판정 상태($STATUS) — 침묵"; exit 0 ;;
esac

# 기록 갱신. 미통지분이 없어도 최초 설치라면 기준선을 세워야 하므로 payload 와 독립이다.
if [ -n "$NEWVER" ]; then
  # 단조 증가 가드 — 두 세션이 동시에 켜지면 양쪽 다 떠도 무해하지만 기록이 **되돌아가서는**
  # 안 된다. 쓰기 직전 현재 값을 다시 읽어, 그것이 내 캐시에 없으면 상대가 더 새 캐시를
  # 봤다는 뜻이므로 물러난다. 있으면 그 인덱스는 0 이상이고 내가 쓰는 것은 인덱스 0 이라
  # 항상 같거나 더 최신이다.
  CUR=""
  [ -r "$STATE" ] && read -r CUR < "$STATE"
  CUR="${CUR//[[:space:]]/}"
  if [ -n "$CUR" ] && [ "$CUR" != "$LAST" ] &&
     ! jq -e --arg v "$CUR" '[.releases[].version] | index($v) != null' "$CACHE" >/dev/null 2>&1; then
    dbg "기록이 그 사이 더 새 값($CUR)으로 바뀜 — 갱신 물러남"
  else
    STATE_DIR="${STATE%/*}"
    # 이미 있으면 mkdir 을 부르지 않는다 — 상시 경로에서 포크 하나를 없앤다.
    [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null
    # 원자적 교체 — 부분 기록 상태로 관측되지 않는다.
    if printf '%s\n' "$NEWVER" > "$STATE.tmp" 2>/dev/null; then
      mv -f "$STATE.tmp" "$STATE" 2>/dev/null || rm -f "$STATE.tmp" 2>/dev/null
      dbg "기록 갱신: ${LAST:-<없음>} → $NEWVER"
    fi
  fi
fi

# 여기까지 온 것은 BASE 아니면 SHOW 다. BASE 는 기준선만 세우고 아무것도 띄우지 않는다 —
# 첫인상이 "설치했더니 뭔가 쏟아짐" 이 되면 안 된다.
if [ -z "$PAYLOAD" ]; then
  exit 0
fi

printf '%s\n' "$PAYLOAD"
exit 0
