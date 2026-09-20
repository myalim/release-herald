#!/usr/bin/env bash
# classify-all.sh 회귀 테스트 — 판정 루프가 실패를 어떻게 다루나.
#
# **이 네 경로가 이 테스트의 존재 이유다** — 루프가 워크플로 `run:` 안에 있을 때는
# 17분짜리 CI 실행 말고는 밟아볼 방법이 없었고, 그중 "0 으로 끝났는데 출력이 없다" 는
# 실제로 일어나야만 관측됐다. 판정기를 가짜로 바꾸면 넷 다 즉시 재현된다.
#
#   사용법: ./scripts/test-classify-all.sh
#   전제:   없음 (판정기를 부르지 않으므로 네트워크·사용량 0)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/classify-all.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}

# 대기 디렉터리를 새로 짓는다. 내용은 루프가 안 보므로 버전 이름만 맞으면 된다.
seed() { # seed <버전...>
  PEND="$TMP/pending"; JUDGED="$TMP/judged"
  rm -rf "$PEND"; mkdir -p "$PEND"
  for v in "$@"; do echo '{"releases":[]}' > "$PEND/$v.json"; done
}

# 가짜 판정기 — 이름에 따라 성공·침묵·실패를 갈라 낸다. 실제 CLI 자리에 그대로 꽂힌다.
FAKE="$TMP/fake.sh"
cat > "$FAKE" <<'EOF'
#!/bin/sh
# $1 입력 · $2 출력
case "$(basename "$1" .json)" in
  *-silent) exit 0 ;;                 # 0 으로 끝나는데 아무것도 안 쓴다
  *-fail)   exit 1 ;;                 # 판정 자체가 실패
  *)        echo '{"version":"x"}' > "$2" ;;
esac
EOF
chmod +x "$FAKE"

run() { CLASSIFY_CMD="$FAKE" "$RUN" "$PEND" "$JUDGED" >"$TMP/out" 2>&1; echo $?; }

echo "── 전부 성공 ──"
seed v2.1.301 v2.1.302
chk "종료코드 0"           "$(run)" "0"
chk "판정 파일이 둘"       "$(find "$JUDGED" -name '*.json' | wc -l | tr -d ' ')" "2"
chk "판정한 개수를 알린다" "$(grep -c '판정한 릴리스 2' "$TMP/out")" "1"

echo "── 0 으로 끝났는데 출력이 없다 ──"
seed v2.1.303-silent
chk "종료코드 1"       "$(run)" "1"
chk "침묵을 짚는다"    "$(grep -c '출력 파일이 없다' "$TMP/out")" "1"

echo "── 판정기가 실패로 끝난다 ──"
seed v2.1.304-fail
chk "종료코드 1"       "$(run)" "1"
chk "실패를 짚는다"    "$(grep -c '판정이 실패로 끝났다' "$TMP/out")" "1"

echo "── 일부만 실패 ──"
# **루프가 멈추면 안 되는 자리다** — 한 건이 어긋났다고 뒤 릴리스를 통째로 버리면 정체가 생긴다.
seed v2.1.305 v2.1.306-fail v2.1.307
chk "종료코드 1"                 "$(run)" "1"
chk "성공분은 그대로 남는다"     "$(find "$JUDGED" -name '*.json' | wc -l | tr -d ' ')" "2"
chk "실패한 버전만 보고한다"     "$(grep -c '판정 실패: v2.1.306-fail$' "$TMP/out")" "1"

echo "── 앞선 실행분 ──"
# 지난 실행의 판정이 남아 있으면 이번 실패가 그것에 가려진다.
seed v2.1.308-fail
mkdir -p "$JUDGED"; echo stale > "$JUDGED/v2.1.299.json"
run >/dev/null
chk "묵은 판정 파일을 지운다" "$([ -e "$JUDGED/v2.1.299.json" ] && echo y || echo n)" "n"

echo "── 대기가 0 ──"
# 이 경로가 로컬에서 안 돌면 "판정할 게 없는 날에는 고쳐도 못 돌려본다" 가 그대로 남는다.
seed
chk "종료코드 0"        "$(run)" "0"
chk "0건이라고 알린다"  "$(grep -c '판정한 릴리스 0' "$TMP/out")" "1"

echo "── 대기 디렉터리가 없다 ──"
PEND="$TMP/없는디렉터리"; JUDGED="$TMP/judged2"
chk "종료코드 2" "$(run)" "2"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ]
