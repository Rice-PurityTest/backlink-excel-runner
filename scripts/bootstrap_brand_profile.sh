#!/usr/bin/env bash
set -euo pipefail

CFG="${1:-/home/gc/.openclaw/workspace/skills/backlink-excel-runner/assets/task-template.json}"

python3 - <<'PY' "$CFG"
import json, sys, re, urllib.request, urllib.parse
from html import unescape
from datetime import datetime

cfg_path = sys.argv[1]
with open(cfg_path, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

target = cfg.get('targetSite', '').strip()
out_path = cfg.get('brandProfilePath', '').strip()

if not target:
    raise SystemExit('targetSite missing in config')
if not out_path:
    raise SystemExit('brandProfilePath missing in config')

if not target.startswith('http'):
    target = 'https://' + target

base = target.rstrip('/')
candidates = [
    base,
    base + '/about',
    base + '/about-us',
    base + '/features',
    base + '/pricing',
    base + '/product',
]

seen = set()
pages = []

def fetch(url):
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (OpenClaw backlink bootstrap)'
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        ct = r.headers.get('Content-Type','')
        data = r.read(300000)
        return ct, data.decode('utf-8', errors='ignore')

def clean_text(html):
    html = re.sub(r'(?is)<script.*?>.*?</script>', ' ', html)
    html = re.sub(r'(?is)<style.*?>.*?</style>', ' ', html)
    text = re.sub(r'(?is)<[^>]+>', ' ', html)
    text = unescape(text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text

def pick(pattern, html):
    m = re.search(pattern, html, re.I|re.S)
    return unescape(m.group(1)).strip() if m else ''

for u in candidates:
    if u in seen:
        continue
    seen.add(u)
    try:
        ct, html = fetch(u)
        if 'html' not in ct and '<html' not in html.lower():
            continue
        title = pick(r'<title[^>]*>(.*?)</title>', html)
        desc = pick(r'<meta[^>]+name=["\']description["\'][^>]+content=["\'](.*?)["\']', html)
        if not desc:
            desc = pick(r'<meta[^>]+property=["\']og:description["\'][^>]+content=["\'](.*?)["\']', html)
        h1s = re.findall(r'(?is)<h1[^>]*>(.*?)</h1>', html)
        h2s = re.findall(r'(?is)<h2[^>]*>(.*?)</h2>', html)
        h1s = [re.sub(r'<[^>]+>', '', unescape(x)).strip() for x in h1s][:5]
        h2s = [re.sub(r'<[^>]+>', '', unescape(x)).strip() for x in h2s][:8]
        text = clean_text(html)[:4000]
        pages.append({
            'url': u,
            'title': title,
            'description': desc,
            'h1': [x for x in h1s if x],
            'h2': [x for x in h2s if x],
            'textSample': text,
        })
    except Exception:
        continue

if not pages:
    raise SystemExit('failed to fetch any page content for targetSite')

primary = pages[0]
site_name = urllib.parse.urlparse(base).netloc
core_desc = primary.get('description') or (primary.get('h1')[0] if primary.get('h1') else '') or primary.get('title') or site_name
core_desc = core_desc.strip()

keywords = []
for p in pages:
    for s in (p.get('h1',[]) + p.get('h2',[])):
        for w in re.findall(r'[A-Za-z][A-Za-z0-9\-]{3,}', s):
            lw = w.lower()
            if lw not in keywords:
                keywords.append(lw)
keywords = keywords[:20]

one_liner_en = f"{site_name} helps users with {core_desc}."
one_liner_cn = f"{site_name} 是一个提供“{core_desc}”相关能力的网站。"

short_en = f"{site_name} is a practical online service focused on {core_desc}. It is useful for users who want fast, accessible workflows without heavy setup."
medium_en = f"{site_name} provides tools and workflows around {core_desc}. It is designed for day-to-day usage with an emphasis on usability and quick results. In submissions or profile descriptions, mention concrete value and use-cases instead of generic promotion."
long_en = f"{site_name} is positioned as a utility-focused product around {core_desc}. Based on the public pages we fetched, it appears to prioritize straightforward usage, clear feature communication, and practical outcomes. For backlink contexts, keep copy natural and contextual: explain why the link is relevant to the thread, article, or profile. Avoid over-claiming and avoid spammy CTA language."

anchor_variants = [
    site_name,
    site_name.replace('www.',''),
    'official site',
    'useful tool',
]

profile = {
    'generatedAt': datetime.utcnow().isoformat() + 'Z',
    'targetSite': base,
    'siteName': site_name,
    'sourcePages': pages,
    'summary': {
        'oneLinerEN': one_liner_en,
        'oneLinerCN': one_liner_cn,
        'shortEN': short_en,
        'mediumEN': medium_en,
        'longEN': long_en,
    },
    'keywords': keywords,
    'anchorVariants': anchor_variants,
    'commentTemplates': {
        'hrefStyleEN': f'I found <a href="{base}">{site_name.replace("www.","")}</a> useful in this context because it directly supports the workflow discussed here.',
        'forumNaturalEN': f'I used {site_name} recently for this type of task and it was helpful, especially for quick validation and iteration.',
        'blogIntroEN': f'If you need a practical option for {core_desc}, {site_name} is worth checking as a lightweight starting point.'
    },
    'rules': {
        'style': 'natural, contextual, non-spam',
        'avoid': ['keyword stuffing', 'overpromising', 'generic ad tone'],
        'htmlAnchorAllowedWhenRequested': True
    }
}

import os
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(profile, f, ensure_ascii=False, indent=2)

print(json.dumps({'ok': True, 'brandProfilePath': out_path, 'pagesFetched': len(pages)}, ensure_ascii=False))
PY