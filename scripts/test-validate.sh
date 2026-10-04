#!/usr/bin/env bash
# build.py 검증 회귀 테스트 — 영역(area) 필드의 계약과, 병합이 계약 위반을 릴리스 단위로 거르는지를 밟는다.
#
# **검증기는 jsonschema 없이 스키마를 직접 읽는 손구현이다** — 스키마에 제약을 적어도 검증기가
# 그 키워드를 모르면 조용히 통과한다. 그래서 스키마가 아니라 검증기의 실제 판정을 본다.
#
#   사용법: ./scripts/test-validate.sh
#   전제:   python3 · jq · data/summaries.json (fixture 원본)

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

PASS=0; FAIL=0
chk() { # chk <이름> <실제> <기대>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  ✗ %s — 기대=%s 실제=%s\n' "$1" "$3" "$2"; fi
}

# 실제 데이터의 첫 항목에 area 를 넣어 검증 결과의 오류 수를 낸다.
# 기존 데이터를 쓰는 것은 다른 필드가 이미 계약을 지키고 있어, 걸리는 것이 area 뿐이기 때문이다.
errs() { # errs <area JSON | __none__>
  python3 - "$HERE" "$1" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import build
data = json.loads((build.ROOT / "data/summaries.json").read_text(encoding="utf-8"))
item = next(r for r in data["releases"] if r["items"])["items"][0]
if sys.argv[2] != "__none__":
    item["area"] = json.loads(sys.argv[2])
print(len(build.validate_data(data)))
PY
}

echo "── 영역 필드 ──"
chk "영역이 없어도 통과(선택 필드)"     "$(errs __none__)"                    "0"
chk "영역 하나"                         "$(errs '["hooks"]')"                 "0"
chk "둘은 거부(둘째 영역은 아직 열지 않음)" "$(errs '["permissions","hooks"]')"   "1"
chk "목록에 없는 값은 거부"             "$(errs '["security"]')"              "1"
chk "빈 배열은 거부"                    "$(errs '[]')"                        "1"
chk "배열이 아니면 거부"                "$(errs '"hooks"')"                   "1"

echo "── 병합 — 계약 위반은 그 릴리스만 거부한다 ──"
# 최신 두 릴리스를 판정 대기로 되돌려 다시 병합한다. 하나에만 80자를 넘는 ko 를 넣는다 — 판정
# (classify.md)은 영역을 내지 않으므로 병합에 실제로 올 수 있는 위반이 이것이다.
# 합친 전체를 한 번에 검증하면 멀쩡한 쪽까지 함께 막히던 형태가 이 경로다.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 - "$HERE" "$TMP" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import build
tmp = sys.argv[2]
data = json.loads((build.ROOT / "data/summaries.json").read_text(encoding="utf-8"))
withitems = [r for r in data["releases"] if r["items"]][:2]
good, bad = json.loads(json.dumps(withitems[0])), json.loads(json.dumps(withitems[1]))
bad["items"][0]["ko"] = "가" * 81
data["releases"] = [r for r in data["releases"] if r["version"] not in (good["version"], bad["version"])]
open(f"{tmp}/summaries.json", "w").write(json.dumps(data, ensure_ascii=False))
pend = [{k: r[k] for k in ("version", "date", "url")} | {"items": [{"kind": i["kind"], "en": i["en"]} for i in r["items"]]} for r in (good, bad)]
open(f"{tmp}/pending.json", "w").write(json.dumps({"releases": pend}, ensure_ascii=False))
import os; os.makedirs(f"{tmp}/judged")
for r in (good, bad):
    open(f"{tmp}/judged/{r['version']}.json", "w").write(json.dumps({"releases": [r]}, ensure_ascii=False))
open(f"{tmp}/names", "w").write(f"{good['version']} {bad['version']}")
PY
read -r GOOD BAD < "$TMP/names"
OUT="$(python3 "$HERE/build.py" merge --pending "$TMP/pending.json" --judged-dir "$TMP/judged" --summaries "$TMP/summaries.json" 2>&1)"
chk "멀쩡한 릴리스는 들어감"            "$(jq --arg v "$GOOD" '[.releases[].version] | index($v) != null' "$TMP/summaries.json")" "true"
chk "위반한 릴리스는 빠짐"              "$(jq --arg v "$BAD" '[.releases[].version] | index($v) != null' "$TMP/summaries.json")" "false"
chk "위반은 사유와 함께 보고됨"         "$(printf '%s' "$OUT" | grep -c "거부: $BAD: 계약 위반")" "1"
chk "병합 결과가 계약을 지킴"           "$(python3 "$HERE/build.py" validate "$TMP/summaries.json" >/dev/null 2>&1 && echo y || echo n)" "y"

echo
echo "통과 $PASS · 실패 $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
