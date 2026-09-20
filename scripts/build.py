#!/usr/bin/env python3
"""releases.atom 에서 요약 재료를 뽑고, 완성된 summaries.json 을 계약과 대조한다.

이 스크립트는 파이프라인의 **양끝**만 맡는다 — 가운데(한국어 요약·impact·weight 판정)는
LLM 이 채운다. P1 에서는 그 단계가 수동이고 P3 에서 CI 호출로 바뀌는데, 경계가
schema/summaries.schema.json 이라 주체가 바뀌어도 이 스크립트는 그대로다.

의존성은 표준 라이브러리뿐이다.

  extract   atom → 중간 JSON (version·date·url·items[kind,en])
  pending   아직 판정되지 않은 릴리스만 추린다 (LLM 입력) · --split-dir 로 릴리스별 분할
  merge     판정 결과를 summaries.json 에 병합한다 (LLM 출력 검사 포함)
  validate  summaries.json 이 스키마를 만족하나
"""

import argparse
import html
import json
import os
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

ATOM_URL = "https://github.com/anthropics/claude-code/releases.atom"
NS = {"a": "http://www.w3.org/2005/Atom"}
ROOT = Path(__file__).resolve().parent.parent

# 원문 접두어 → kind. 실측(2026-09-01, 277항목)에서 Fixed 176 · Changed 28 · Improved 23 ·
# Added 21 이었고 나머지는 [VSCode]·Bug·/goal: 처럼 흩어져 other 로 접힌다.
# kind 는 원문에서 유래한 **사실**이라 impact 판정이 바뀌어도 다시 뽑을 필요가 없다.
KIND_BY_PREFIX = {
    "added": "added",
    "changed": "changed",
    "improved": "improved",
    "fixed": "fixed",
}


def strip_html(fragment: str) -> str:
    """<li> 안의 HTML 을 읽을 수 있는 평문으로 만든다.

    <code> 만 백틱으로 살린다 — 옵션명·플래그·이벤트명이 그 안에 들어 있고, 그것이
    Claude 가 나중에 정확히 짚어야 할 식별자다(PRD F2). 나머지 태그는 버린다.
    """
    s = re.sub(r"<code>(.*?)</code>", r"`\1`", fragment, flags=re.S)
    s = re.sub(r"<[^>]+>", "", s)
    # 원문이 이중 인코딩된 자리가 있다(`claude attach &lt;id&gt;` 처럼) — ElementTree 가
    # 한 겹 풀어 주므로 남은 한 겹을 여기서 푼다.
    s = html.unescape(s)
    return " ".join(s.split())


# 플랫폼·영역 접두어. 실측에서 `[VSCode] Fixed …`·`Windows: Fixed …` 처럼 동사 앞에 붙어
# 그대로 읽으면 전부 other 로 빠졌다(11개 중 4개).
PREFIX_RE = re.compile(r"^(\[[^\]]+\]|[A-Za-z][A-Za-z/ ]{0,20}:)\s*")
# 버전이 판정 입출력의 **파일명**이 되므로, 경로 구분자·상대경로가 섞이지 않는지 본다.
VERSION_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def kind_of(text: str) -> str:
    """원문 접두어에서 kind 를 읽는다.

    원문 그대로 먼저 보고, 못 읽었을 때만 접두어를 벗겨 다시 본다 — 순서를 뒤집으면
    `Added a new command: /foo` 처럼 문장 중간의 콜론까지 접두어로 잘라 오탐이 난다.
    두 번 다 못 읽으면 other 다. `Removed`·`Updated` 처럼 드문 동사(각 1건)를 enum 에
    들이지 않는 이유는, kind 가 원문에서 유래한 **사실**이라 해석을 섞으면 그 성질을 잃기
    때문이다 — 실제 판정은 impact·weight 가 한다.
    """
    for candidate in (text, PREFIX_RE.sub("", text)):
        words = candidate.split()
        first = words[0].rstrip(":").lower() if words else ""
        if first in KIND_BY_PREFIX:
            return KIND_BY_PREFIX[first]
    return "other"


def extract(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as r:
        raw = r.read()
    root = ET.fromstring(raw)

    releases = []
    for e in root.findall("a:entry", NS):
        updated = (e.findtext("a:updated", "", NS) or "")[:10]
        link = e.find("a:link", NS)
        href = link.get("href") if link is not None else ""
        # version 은 통지 기록과 문자열 일치로 대조하는 키라 태그 그 자체여야 한다. title 은
        # 사람이 붙이는 릴리스 **이름**이고 — 지금은 태그와 같지만 그것이 계약은 아니다 —
        # 이름이 붙는 날 pattern 에 걸려 생성이 멈춘다. href 의 /tag/ 뒤가 태그를 확정적으로 준다.
        version = (
            href.rsplit("/tag/", 1)[-1]
            if "/tag/" in href
            else (e.findtext("a:title", "", NS) or "").strip()
        )
        content = e.findtext("a:content", "", NS) or ""

        items = []
        for li in re.findall(r"<li>(.*?)</li>", content, flags=re.S):
            text = strip_html(li)
            if text:
                items.append({"kind": kind_of(text), "en": text})

        releases.append(
            {"version": version, "date": updated, "url": href, "items": items}
        )

    # atom 이 최신 우선으로 주지만 그것에 기대지 않는다 — 정렬이 계약이고(SPEC 4절),
    # 그 계약을 지키는 책임이 생성기에 있다. sort 가 안정 정렬이라 같은 날짜는 피드 순서를
    # 그대로 유지한다.
    releases.sort(key=lambda r: r["date"], reverse=True)
    return {"source": url, "releases": releases}


# ── 판정 전후 ─────────────────────────────────────────────────────────────
# 가운데(요약·분류)를 LLM 이 채우므로, 그 앞에서 **무엇을 물을지**를 좁히고 뒤에서 **답을 검사**한다.
# 이미 판정된 버전을 다시 묻지 않는 것이 재현성과 사용량 양쪽에 걸린다.


def pending(extracted: Path, summaries: Path, out: Path, split_dir: Path = None) -> int:
    """summaries.json 에 없는 릴리스만 추려 낸다.

    kind·en 만 넘긴다 — 판정에 필요한 것이 그것뿐이고, 나머지를 함께 주면 LLM 이 고칠 여지가
    생긴다. 실제로 고쳐졌는지는 merge 가 대조한다.
    """
    ext = json.loads(extracted.read_text(encoding="utf-8"))
    known = set()
    if summaries.exists():
        known = {r.get("version") for r in json.loads(summaries.read_text(encoding="utf-8")).get("releases", [])}

    fresh = [
        {
            "version": r["version"],
            "date": r["date"],
            "url": r["url"],
            "items": [{"kind": i["kind"], "en": i["en"]} for i in r["items"]],
        }
        for r in ext["releases"]
        if r["version"] not in known
    ]
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"releases": fresh}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    # split_dir 이 주어지면 **릴리스마다 한 파일**을 더 쓴다 — 판정을 릴리스마다 나눠 부르기 위한 입력이다.
    # 파일 하나의 형태는 통짜 pending.json 과 같게 둔다 — 프롬프트와 merge 의 계약이 릴리스 수와
    # 무관해진다.
    if split_dir is not None:
        # 앞선 실행분이 남으면 이미 판정된 릴리스를 다시 묻게 된다.
        if split_dir.exists():
            for stale in split_dir.glob("*.json"):
                stale.unlink()
        split_dir.mkdir(parents=True, exist_ok=True)
        for r in fresh:
            if not VERSION_RE.fullmatch(r["version"]):
                raise ValueError(f"파일명으로 쓸 수 없는 버전: {r['version']!r}")
            body = {"releases": [r]}
            (split_dir / f"{r['version']}.json").write_text(
                json.dumps(body, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
            )
    return len(fresh)


def _judged_releases(judged_file: Path) -> tuple:
    """판정 결과를 읽는다. 없거나 깨졌으면 traceback 대신 사유를 돌려준다.

    액션이 성공으로 끝나고도 파일을 안 쓸 수 있다(턴 예산 소진 등). 그때 계약 위반을
    알리는 도구가 스스로 죽으면 무엇이 잘못됐는지가 로그에서 사라진다.
    """
    try:
        data = json.loads(judged_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, [f"{judged_file.name} 이 없다 — 판정 단계가 아무것도 쓰지 않았다"]
    except json.JSONDecodeError as e:
        return None, [f"{judged_file.name} 이 JSON 이 아니다: {e}"]
    rel = data.get("releases") if isinstance(data, dict) else None
    if not isinstance(rel, list) or not all(isinstance(r, dict) for r in rel):
        return None, [f"{judged_file.name}: releases 가 객체 배열이 아니다"]
    return rel, []


def _judged_from_dir(judged_dir: Path) -> tuple:
    """릴리스별 판정 파일을 모아 하나의 목록으로 만든다 — 판정을 릴리스마다 나눠 부르므로 결과도 나뉜다.

    **못 읽은 파일에서 멈추지 않는다** — 분할의 목적이 실패 격리다. 사유만 모아 merge 로 넘긴다.
    """
    if not judged_dir.is_dir():
        return None, [f"{judged_dir.name}/ 이 없다 — 판정 단계가 아무것도 쓰지 않았다"]
    files = sorted(judged_dir.glob("*.json"))
    if not files:
        return None, [f"{judged_dir.name}/ 이 비어 있다 — 판정 단계가 아무것도 쓰지 않았다"]

    releases, errs = [], []
    for f in files:
        got, e = _judged_releases(f)
        if got is None:
            errs.extend(e)
            continue
        releases.extend(got)
    return releases, errs


def _reject_reason(asked: dict, got: dict) -> str:
    """물은 것과 받은 것을 대조한다. 어긋나면 사유, 멀쩡하면 빈 문자열.

    **`kind`·`en` 만 보면 부족하다** — `date` 가 바뀌면 정렬이 뒤집히고, 그 뒤집힘은 병합이
    스스로 정렬한 결과를 검증이 같은 키로 다시 보는 구조라 잡히지 않는다(동어반복). 훅은
    마지막 통지 버전의 인덱스 앞을 취하므로, 아래로 밀린 릴리스는 영영 통지되지 않는다.
    `url` 은 사용자가 원문으로 가는 유일한 길이라 함께 본다.
    """
    for field in ("date", "url"):
        if got.get(field) != asked[field]:
            return f"{field} 가 바뀜"
    items, src = got.get("items", []), asked["items"]
    if len(items) != len(src):
        return f"항목 수가 다름 ({len(src)} → {len(items)})"
    for n, (a, b) in enumerate(zip(src, items)):
        if b.get("kind") != a["kind"] or b.get("en") != a["en"]:
            return f"{n}번째 항목의 원문이 바뀜"
    return ""


def merge(pending_file: Path, judged_dir: Path, summaries: Path) -> tuple:
    """판정 결과를 병합한다. **통과분만 넣고 어긋난 것은 사유와 함께 돌려준다.**

    전부 거부하지 않는 이유는 정체다 — 한 릴리스가 계속 어긋나면 나머지까지 함께 멈추고,
    원본이 좁은 창이라 그 사이 릴리스가 사라진다. 대신 거부가 있으면 호출한 쪽이 빨간 run 으로
    끝내 저자에게는 침묵하지 않는다.

    쓰기는 **검증을 통과한 뒤 원자적으로** 한다. 이 파일이 훅과의 유일한 접점이라 미검증
    상태나 부분 상태로 존재해서는 안 된다(SPEC 불변식).

    돌려주는 것은 (거부 사유 목록, 병합한 버전 목록) — 커밋 메시지가 그 목록을 제목에 쓴다.
    """
    asked = {r["version"]: r for r in json.loads(pending_file.read_text(encoding="utf-8"))["releases"]}
    # 일부가 깨져도 나머지는 이어서 본다 — 아무것도 못 읽었을 때만(got is None) 중단한다.
    got, errs = _judged_from_dir(judged_dir)
    if got is None:
        return errs, []

    # handled 는 "이 버전을 다뤘다" 이지 "받아들였다" 가 아니다 — 거부한 버전을 빼지 않으면
    # 아래 누락 검사에 다시 걸려 한 결함이 두 줄로 보고된다.
    accepted, handled = [], set()
    for r in got:
        v = r.get("version")
        if v not in asked:
            errs.append(f"{v!r}: 묻지 않은 버전")
            continue
        if v in handled:
            # 훅은 일치하는 **첫** 원소를 찾으므로, 중복이 들어가면 미통지 구간이 잘린다.
            errs.append(f"{v}: 판정 결과에 중복")
            continue
        handled.add(v)
        reason = _reject_reason(asked[v], r)
        if reason:
            errs.append(f"{v}: {reason}")
            continue
        accepted.append(r)

    for v in sorted(set(asked) - handled):
        errs.append(f"{v}: 판정이 없음")

    if not accepted:
        return errs, []

    data = json.loads(summaries.read_text(encoding="utf-8"))
    data["releases"] = sorted(accepted + data["releases"], key=_order_key, reverse=True)
    data["generated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    broken = validate_data(data)
    if broken:
        # 여기까지 왔는데 계약을 어겼다면 대조가 못 잡는 종류다 — 쓰지 않고 그대로 알린다.
        return errs + [f"병합 결과가 계약 위반: {m}" for m in broken], []

    tmp = summaries.with_name(summaries.name + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, summaries)
    return errs, sorted(r["version"] for r in accepted)


# ── 검증 ──────────────────────────────────────────────────────────────────
# jsonschema 를 쓰지 않는다 — 의존성을 표준 라이브러리로 묶었다. 계약이 얕아 필요한 제약이
# required·enum·pattern·범위뿐이고, 그것만 직접 본다.


def _check(obj, spec, defs, path, errs):
    if not isinstance(obj, dict):
        errs.append(f"{path}: 객체가 아님")
        return
    props = spec.get("properties", {})
    for k in spec.get("required", []):
        if k not in obj:
            errs.append(f"{path}: 필수 키 '{k}' 없음")
    if spec.get("additionalProperties") is False:
        for k in obj:
            if k not in props:
                errs.append(f"{path}: 계약에 없는 키 '{k}'")
    for k, v in obj.items():
        p = props.get(k)
        if not p:
            continue
        here = f"{path}.{k}"
        if "const" in p and v != p["const"]:
            errs.append(f"{here}: {p['const']} 이어야 함 → {v!r}")
        if "enum" in p and v not in p["enum"]:
            errs.append(f"{here}: {p['enum']} 중 하나여야 함 → {v!r}")
        # fullmatch 를 쓴다 — match 는 `$` 가 끝의 개행 앞에서도 맞아 "v2.1.251\n" 이 통과하고,
        # 훅이 통지 기록과 문자열 일치로 대조하므로 그런 값은 영영 매칭되지 않아 매 세션 재통지된다.
        if "pattern" in p and not re.fullmatch(p["pattern"], str(v)):
            errs.append(f"{here}: 형식 불일치 → {v!r}")
        if p.get("type") == "integer":
            if not isinstance(v, int) or isinstance(v, bool):
                errs.append(f"{here}: 정수여야 함 → {v!r}")
            elif not p.get("minimum", -1 << 62) <= v <= p.get("maximum", 1 << 62):
                errs.append(f"{here}: 범위 밖 → {v}")
        if p.get("type") == "string":
            if not isinstance(v, str):
                errs.append(f"{here}: 문자열이어야 함 → {v!r}")
            elif len(v) < p.get("minLength", 0):
                errs.append(f"{here}: 비어 있음")
            elif "maxLength" in p and len(v) > p["maxLength"]:
                # 이 상한이 곧 "화면 한 줄" 계약이라, 안 보면 계약이 없는 것과 같다.
                errs.append(f"{here}: {p['maxLength']}자 상한 초과 ({len(v)}자)")
        if p.get("type") == "array":
            if not isinstance(v, list):
                errs.append(f"{here}: 배열이어야 함")
                continue
            ref = p.get("items", {}).get("$ref", "")
            name = ref.rsplit("/", 1)[-1] if ref else None
            if name:
                for i, el in enumerate(v):
                    _check(el, defs[name], defs, f"{here}[{i}]", errs)


def _order_key(release: dict) -> tuple:
    """정렬 검증 전용 키. 버전은 문자열이 아니라 정수 튜플로 비교한다.

    훅의 통지 판정에는 버전 대소 비교가 없고(인덱스로 찾는다 — SPEC 4절) 여기서도 되살리지
    않는다. 이 비교는 그 인덱스 판정이 딛는 **순서 자체**를 생성 시점에 확인하는 용도이고,
    정수 튜플이라 v2.1.9 > v2.1.10 이 되는 문자열 비교의 함정도 없다.
    """
    return (release.get("date", ""), tuple(int(n) for n in re.findall(r"\d+", str(release.get("version", "")))))


def validate_data(data: dict, label: str = "summaries") -> list:
    """디스크가 아니라 **데이터**를 검증한다 — merge 가 쓰기 전에 같은 검사를 돌린다."""
    schema = json.loads((ROOT / "schema/summaries.schema.json").read_text(encoding="utf-8"))
    errs = []
    _check(data, schema, schema["$defs"], label, errs)

    releases = data.get("releases")
    # 형태 오류는 위에서 이미 보고했다. 그래도 순회하면 보고 대신 traceback 이 나가고,
    # 계약 위반을 알리는 것이 이 도구의 존재 이유라 그 자리에서 빈손이 된다.
    if not isinstance(releases, list) or not all(isinstance(r, dict) for r in releases):
        return errs

    # 정렬은 JSON Schema 로 표현되지 않아 계약이 SPEC 4절에 있다 — 훅이 인덱스로 판정하므로
    # 이 순서가 깨지면 통지가 조용히 어긋난다. 날짜만 보면 같은 날 두 릴리스의 역전을 놓치는데,
    # 원본 피드에 같은 날짜 쌍이 실제로 있고 그 역전이 곧 통지 누락이다.
    keys = [_order_key(r) for r in releases]
    if keys != sorted(keys, reverse=True):
        errs.append("releases: 최신 우선 정렬이 아님 (SPEC 4절 계약)")

    # 훅은 통지 기록과 일치하는 **첫** 원소를 찾으므로, 중복이 있으면 미통지 구간이 잘린다.
    seen = set()
    for r in releases:
        v = r.get("version")
        if v in seen:
            errs.append(f"releases: version 중복 → {v!r}")
        seen.add(v)
    return errs


def validate(path: Path) -> list:
    return validate_data(json.loads(path.read_text(encoding="utf-8")), path.name)


def main() -> int:
    # 한국어 요약과 ✓ 를 읽고 쓰므로 로케일 기본값에 맡기지 않는다 — LC_ALL=C 나 Windows
    # 기본 인코딩에서 UnicodeDecodeError/UnicodeEncodeError 로 죽는다.
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8")

    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("extract", help="atom 에서 요약 재료를 뽑는다")
    e.add_argument("--url", default=ATOM_URL)
    e.add_argument("--out", type=Path, default=ROOT / "data/extracted.json")

    pd = sub.add_parser("pending", help="아직 판정되지 않은 릴리스만 추린다")
    pd.add_argument("--extracted", type=Path, default=ROOT / "data/extracted.json")
    pd.add_argument("--summaries", type=Path, default=ROOT / "data/summaries.json")
    pd.add_argument("--out", type=Path, default=ROOT / "data/pending.json")
    pd.add_argument("--split-dir", type=Path, default=None, help="릴리스마다 한 파일씩 더 쓴다")

    mg = sub.add_parser("merge", help="판정 결과를 summaries.json 에 병합한다")
    mg.add_argument("--pending", type=Path, default=ROOT / "data/pending.json")
    mg.add_argument("--judged-dir", type=Path, default=ROOT / "data/judged", help="릴리스별 판정 파일이 있는 디렉터리")
    mg.add_argument("--summaries", type=Path, default=ROOT / "data/summaries.json")

    v = sub.add_parser("validate", help="summaries.json 을 계약과 대조한다")
    v.add_argument("file", type=Path)

    args = ap.parse_args()

    if args.cmd == "extract":
        data = extract(args.url)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        total = sum(len(r["items"]) for r in data["releases"])
        shown = args.out.relative_to(ROOT) if args.out.is_relative_to(ROOT) else args.out
        print(f"✓ {shown} — 릴리스 {len(data['releases'])} · 항목 {total}")
        empty = [r["version"] for r in data["releases"] if not r["items"]]
        if empty:
            print(f"  항목 없는 릴리스: {', '.join(empty)}")
        return 0

    if args.cmd == "pending":
        n = pending(args.extracted, args.summaries, args.out, args.split_dir)
        print(f"✓ 판정 대기 릴리스 {n}")
        # 대기가 없으면 뒤 단계를 통째로 건너뛰어야 한다 — 빈 판정을 LLM 에 묻는 것은
        # 사용량만 쓰고 아무것도 바꾸지 않는다.
        gh = os.environ.get("GITHUB_OUTPUT")
        if gh:
            with open(gh, "a", encoding="utf-8") as f:
                f.write(f"count={n}\n")
        return 0

    if args.cmd == "merge":
        errs, merged = merge(args.pending, args.judged_dir, args.summaries)
        print(f"✓ {args.summaries.name} — 병합한 릴리스 {len(merged)}: {', '.join(merged) or '없음'}")
        for m in errs:
            print(f"  거부: {m}", file=sys.stderr)
        # 거부가 있어도 통과분은 이미 들어갔으므로 여기서 죽지 않는다 — 커밋까지 마친 뒤
        # 호출한 쪽이 빨간 run 으로 끝내 저자에게 알린다.
        gh = os.environ.get("GITHUB_OUTPUT")
        if gh:
            with open(gh, "a", encoding="utf-8") as f:
                f.write(f"rejected={len(errs)}\n")
                f.write(f"merged={', '.join(merged)}\n")
        return 0

    errs = validate(args.file)
    if errs:
        print(f"✗ {args.file} — 계약 위반 {len(errs)}", file=sys.stderr)
        for m in errs:
            print(f"  {m}", file=sys.stderr)
        return 1
    print(f"✓ {args.file} — 계약 통과")
    return 0


if __name__ == "__main__":
    sys.exit(main())
