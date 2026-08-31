#!/usr/bin/env python3
"""releases.atom 에서 요약 재료를 뽑고, 완성된 summaries.json 을 계약과 대조한다.

이 스크립트는 파이프라인의 **양끝**만 맡는다 — 가운데(한국어 요약·impact·weight 판정)는
LLM 이 채운다. P1 에서는 그 단계가 수동이고 P3 에서 CI 호출로 바뀌는데, 경계가
schema/summaries.schema.json 이라 주체가 바뀌어도 이 스크립트는 그대로다 (decisions D4·D6).

의존성은 표준 라이브러리뿐이다 — 하나라도 붙으면 P3 의 CI 재현 비용이 그만큼 는다.

  extract   atom → 중간 JSON (version·date·url·items[kind,en])
  validate  summaries.json 이 스키마를 만족하나
"""

import argparse
import html
import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
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
        version = (e.findtext("a:title", "", NS) or "").strip()
        updated = (e.findtext("a:updated", "", NS) or "")[:10]
        link = e.find("a:link", NS)
        href = link.get("href") if link is not None else ""
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
    # 그 계약을 지키는 책임이 생성기에 있다. 날짜 역순 + 원래 순서로 안정 정렬한다.
    order = {id(r): i for i, r in enumerate(releases)}
    releases.sort(key=lambda r: (r["date"], -order[id(r)]), reverse=True)
    return {"source": url, "releases": releases}


# ── 검증 ──────────────────────────────────────────────────────────────────
# jsonschema 를 쓰지 않는다(D6 단서: 표준 라이브러리만). 계약이 얕아 필요한 제약이
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
        if "pattern" in p and not re.match(p["pattern"], str(v)):
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
        if p.get("type") == "array":
            if not isinstance(v, list):
                errs.append(f"{here}: 배열이어야 함")
                continue
            ref = p.get("items", {}).get("$ref", "")
            name = ref.rsplit("/", 1)[-1] if ref else None
            if name:
                for i, el in enumerate(v):
                    _check(el, defs[name], defs, f"{here}[{i}]", errs)


def validate(path: Path) -> list:
    schema = json.loads((ROOT / "schema/summaries.schema.json").read_text())
    data = json.loads(path.read_text())
    errs = []
    _check(data, schema, schema["$defs"], path.name, errs)

    # 정렬은 JSON Schema 로 표현되지 않아 계약이 SPEC 4절에 있다 — 훅이 인덱스로 판정하므로
    # 이 순서가 깨지면 통지가 조용히 어긋난다. 검증이 여기 있어야 하는 이유다.
    dates = [r.get("date", "") for r in data.get("releases", [])]
    if dates != sorted(dates, reverse=True):
        errs.append("releases: 최신 우선 정렬이 아님 (SPEC 4절 계약)")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("extract", help="atom 에서 요약 재료를 뽑는다")
    e.add_argument("--url", default=ATOM_URL)
    e.add_argument("--out", type=Path, default=ROOT / "data/extracted.json")

    v = sub.add_parser("validate", help="summaries.json 을 계약과 대조한다")
    v.add_argument("file", type=Path)

    args = ap.parse_args()

    if args.cmd == "extract":
        data = extract(args.url)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
        total = sum(len(r["items"]) for r in data["releases"])
        print(f"✓ {args.out.relative_to(ROOT)} — 릴리스 {len(data['releases'])} · 항목 {total}")
        empty = [r["version"] for r in data["releases"] if not r["items"]]
        if empty:
            print(f"  항목 없는 릴리스: {', '.join(empty)}")
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
