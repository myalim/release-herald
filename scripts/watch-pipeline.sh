#!/usr/bin/env bash
# 요약 파이프라인 감시 — 생성이 멈춘 것을 저자에게 이슈로 알린다.
#
# 이 설계는 모든 실패가 사용자 화면에서 침묵으로 수렴한다. 그래서 생성 측이 멈추면 사용자에게는
# "요즘 릴리스가 없나 보다" 로만 보이고, 원본(atom)이 9일 창이라 그만큼 쉬면 데이터가 영구히
# 사라진다. 저자 쪽 관측만은 침묵하지 않게 하는 것이 이 스크립트다.
#
# 잡는 멈춤은 둘이다 —
#   failure  요약 job 이 성공으로 끝나지 않았다 (실패·취소·시간 초과)
#   stale    성공으로 끝났는데 반영이 없다 — 창 안의 상류 릴리스가 게시 STALE_DAYS 일이 지나도
#            요약에 없다. 공식 액션이 판정을 건너뛰고 초록으로 끝난 일이 실제로 있었다.
# 예약 실행 자체가 안 도는 멈춤은 이 저장소 안에서 잡을 수 없다(감시도 함께 멈춘다) — 저장소 밖
# 오너 설정의 훅이 받는다.
#
# 이슈는 경보 라벨이 붙은 열린 이슈 하나만 쓴다 —
#   문제가 있고 열린 이슈가 없으면 연다(오너 멘션) · 있으면 문제 종류가 바뀔 때만 댓글을 단다
#   문제가 없고 열린 이슈가 있으면 복구 댓글을 달고 닫는다
# 3시간마다 도는 실행이 같은 경보를 매번 댓글로 쌓으면 알림이 소음이 되어 읽히지 않는다.
#
#   사용법: RESULT=<success|failure|cancelled> scripts/watch-pipeline.sh
#   환경:   GH_TOKEN(issues: write) · REPO · OWNER · RUN_URL
#           STALE_DAYS(기본 3) · WINDOW_DAYS(기본 9) · SUMMARIES · UPSTREAM · NOW(테스트용 epoch)

set -u

RESULT="${RESULT:?RESULT 가 필요하다}"
REPO="${REPO:?REPO 가 필요하다}"
OWNER="${OWNER:?OWNER 가 필요하다}"
RUN_URL="${RUN_URL:-}"
STALE_DAYS="${STALE_DAYS:-3}"
WINDOW_DAYS="${WINDOW_DAYS:-9}"
SUMMARIES="${SUMMARIES:-data/summaries.json}"
UPSTREAM="${UPSTREAM:-anthropics/claude-code}"
NOW="${NOW:-$(date +%s)}"
LABEL="pipeline-alert"
TITLE="요약 파이프라인 경보"

# 이슈를 읽고 쓰는 gh 호출은 실패하면 이번 실행을 실패로 끝낸다 — 조회 실패를 "열린 이슈 없음" 으로
# 읽으면 같은 경보가 새 이슈·댓글로 쌓이고, 쓰기 실패를 넘기면 경보를 못 냈는데 job 이 초록으로 남는다.
# 감시가 침묵하지 않게 하는 것이 이 스크립트의 존재 이유라, 호출마다 정책을 따로 두지 않는다.
must() { "$@" || { echo "gh 호출 실패 — 이번 실행은 실패로 끝낸다: $1 $2 $3" >&2; exit 1; }; }

kinds=()
detail=""

if [ "$RESULT" != "success" ]; then
  kinds+=("failure")
  detail+="- 요약 job 이 \`$RESULT\` 로 끝났습니다${RUN_URL:+ — $RUN_URL}"$'\n'
fi

# 창 안(게시 WINDOW_DAYS 일 이내)에서 STALE_DAYS 일이 지났는데 요약에 없는 상류 릴리스.
# 창 밖으로 나간 릴리스는 되찾을 수 없어 경보를 계속 내면 소음만 된다.
# 상류 조회가 실패하면 stale 은 판정하지 않는다 — 모르는 것을 경보로 만들지 않는다.
# 같은 판정이 저장소 밖 오너 감시 훅(~/.claude/hooks/release-herald-watch.sh)에 의도적 사본으로 있다 —
# 창·임계값을 바꾸면 그쪽도 함께 고친다(그쪽은 캐시가 잘린 앞쪽을 세지 않는 조건이 하나 더 있다).
if releases=$(gh api "repos/$UPSTREAM/releases?per_page=30" \
      --jq '.[] | select(.draft | not) | "\(.tag_name) \(.published_at)"' 2>/dev/null); then
  missing=$(printf '%s\n' "$releases" | jq -R -r -s \
      --slurpfile s "$SUMMARIES" --argjson now "$NOW" \
      --argjson stale "$STALE_DAYS" --argjson window "$WINDOW_DAYS" '
    ([$s[0].releases[].version]) as $have
    | split("\n") | map(select(length > 0) | split(" "))
    | map({tag: .[0], age: (($now - (.[1] | fromdateiso8601)) / 86400)})
    | map(select(.age >= $stale and .age < $window and (.tag as $t | $have | index($t) | not)))
    | .[] | "- 요약에 없는 릴리스: \(.tag) (게시 \(.age | floor)일 경과)"')
  if [ -n "$missing" ]; then
    kinds+=("stale")
    detail+="$missing"$'\n'
  fi
else
  echo "상류 릴리스 조회 실패 — 반영 지연은 이번 실행에서 판정하지 않는다" >&2
fi

open=$(must gh issue list --repo "$REPO" --label "$LABEL" --state open --json number --jq '.[0].number // empty') || exit 1

if [ "${#kinds[@]}" -eq 0 ]; then
  if [ -n "$open" ]; then
    must gh issue comment "$open" --repo "$REPO" --body "복구됐습니다${RUN_URL:+ — $RUN_URL}"
    must gh issue close "$open" --repo "$REPO"
    echo "경보 이슈 #$open 을 닫았다"
  fi
  exit 0
fi

# 문제 종류를 표식으로 남겨, 다음 실행이 같은 경보인지 가른다.
kind_key=$(IFS=,; echo "${kinds[*]}")
marker="<!-- watch:$kind_key -->"
body="$detail"$'\n'"$marker"

if [ -z "$open" ]; then
  # 라벨이 없으면 이슈 생성이 실패한다 — 첫 경보에서만 걸리는 경로라 매번 보장한다.
  must gh label create "$LABEL" --repo "$REPO" --color B60205 --force >/dev/null
  must gh issue create --repo "$REPO" --title "$TITLE" --label "$LABEL" --assignee "$OWNER" \
    --body "@$OWNER 요약 파이프라인이 멈춘 것 같습니다. 원본은 ${WINDOW_DAYS}일 창이라 그 안에 고쳐야 데이터가 남습니다."$'\n\n'"$body"
  exit 0
fi

# 열린 이슈의 마지막 표식과 같으면 이미 알린 경보다.
last=$(must gh issue view "$open" --repo "$REPO" --json body,comments \
  --jq '[.body, (.comments[].body)] | map(capture("<!-- watch:(?<k>[a-z,]+) -->").k // empty) | last // ""') || exit 1
if [ "$last" != "$kind_key" ]; then
  must gh issue comment "$open" --repo "$REPO" --body "경보가 바뀌었습니다."$'\n\n'"$body"
fi
