#!/usr/bin/env python3
import argparse
import json
import re
import sys

BAD_TITLE_PATTERNS = [
    re.compile(r"^\s*.+\s+for\s+(fast|quick|better|easy|faster)\s+", re.I),
    re.compile(r"\b(best|ultimate|amazing|powerful)\b", re.I),
]

BAD_BODY_PATTERNS = [
    re.compile(r"\b(practical option|game\s*changer|revolutionary|best tool)\b", re.I),
]


def looks_chinese(text: str) -> bool:
    return bool(re.search(r"[\u4e00-\u9fff]", text))


def main() -> int:
    p = argparse.ArgumentParser(description="Quality guard for backlink text content")
    p.add_argument("--title", required=True)
    p.add_argument("--body", required=True)
    p.add_argument("--target-url", required=True)
    args = p.parse_args()

    title = args.title.strip()
    body = args.body.strip()
    target = args.target_url.strip()

    errors = []
    warnings = []

    # title length
    if looks_chinese(title):
        if not (16 <= len(title) <= 30):
            warnings.append("title_length_cn_out_of_range")
    else:
        if not (45 <= len(title) <= 72):
            warnings.append("title_length_en_out_of_range")

    for pat in BAD_TITLE_PATTERNS:
        if pat.search(title):
            errors.append("title_template_or_hype_detected")
            break

    # body quality
    plain = re.sub(r"\s+", " ", body)
    if len(plain) < 180:
        errors.append("body_too_short")

    # avoid one-line promo + url
    sentence_count = len(re.findall(r"[.!?。！？]", body))
    if sentence_count <= 2 and target in body:
        errors.append("body_looks_like_one_line_promo")

    if target not in body:
        errors.append("target_url_missing_in_body")

    if "%5Cn" in body or "\\n" in body:
        warnings.append("escaped_newline_found_check_link_format")

    for pat in BAD_BODY_PATTERNS:
        if pat.search(body):
            warnings.append("marketing_phrase_detected")
            break

    out = {
        "ok": len(errors) == 0,
        "errors": errors,
        "warnings": warnings,
        "title": title,
        "targetUrl": target,
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0 if out["ok"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
