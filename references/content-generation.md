# Content Generation Rules

## Goal
Produce human-like, context-fitting copy that passes community norms and avoids obvious ad/template patterns.

## 1) Language + tone selection
1. Detect page language from UI and nearby posts.
2. Match host tone:
   - technical forum: concise, concrete, problem/solution
   - community post: conversational, personal experience
   - directory/form: factual, feature-oriented, low hype
3. Keep relevance to the thread/topic; no generic promotion blocks.

## 2) Method-aware writing mode (from column B)
- `论坛` / comment / reply:
  - 2-5 sentences
  - one clear opinion + one concrete use case
  - optional soft CTA at end
- `写文章` / blog/article:
  - title + 3 short sections: context -> approach -> result
  - at least one specific detail (workflow, metric, or comparison)
- `表单` / listing profile:
  - neutral wording, product facts
  - avoid subjective superlatives

## 3) Title generation (mandatory for articles)
Generate 3 candidates first, then pick one.

### Title quality constraints
- Length: 45-72 characters (English), 16-30 chars (Chinese) where possible.
- Must include a concrete context word (workflow/case/notes/lessons/from-to/test).
- Must NOT be template-y.

### Disallowed title patterns
- `<Brand> for <Generic Benefit>`
- `Best/Ultimate/Amazing <anything>`
- Pure SEO keyword stack titles

### Preferred patterns
- `How I used <Brand> to <specific workflow result>`
- `<Task> workflow notes with <Brand>`
- `From <old method> to <new method>: <Brand> in practice`

## 4) Body structure (mandatory)
Use this order:
1. **Context**: what you were trying to do
2. **Approach**: how you used the tool
3. **Result**: what improved / what tradeoff exists
4. **Soft CTA**: natural ending sentence

### Hard constraints
- Do not publish single-paragraph ad copy with only a URL.
- Do not place the link as a standalone line unless platform forces it.
- Keep paragraphs short (1-3 lines each).

## 5) Link and anchor rules
- Link must be semantically embedded in a sentence.
- Verify href exactly equals target domain intent (no accidental newline encoding like `%5Cn`).
- For HTML-anchor-required rows, use:
  - `<a href="https://target-domain">natural anchor text</a>`
- Record rendered evidence (`href`, visible text, `rel`).

## 6) Pre-publish QA gate (mandatory)
Before clicking publish/submit, pass all checks:
1. Title is not template-ad style.
2. First paragraph states a real context.
3. Content has approach + result (not just slogan).
4. Outbound link is correctly formatted and clickable.
5. Link is context-embedded, not naked spam.
6. Tone matches host page language/community style.
7. No exaggerated guarantees (ranking/dofollow certainty).
8. Read once as a human: would this feel like a genuine post?

If any check fails, rewrite once before submit.

## 7) Anti-patterns (do not use)
- "<Brand> is a practical option" + naked URL + generic closing.
- Repeated boilerplate openings across sites.
- Overuse of marketing adjectives (powerful/amazing/best/ultimate).
- Off-topic comments that only inject a link.

## 8) Quick examples

### Bad (article)
`Exact Statement for Fast AI-Assisted Writing`

`If you need quick help drafting and polishing text, Exact Statement is a practical option...`

### Better (article)
`From rough draft to publish-ready: how I use Exact Statement in daily writing`

`I usually start with messy notes from meetings. With Exact Statement, I run one pass for structure and another for tone. It saves me editing time, especially when I need a concise final version. I still manually fact-check, but the rewrite loop is much faster. If you want to test a similar workflow, I used it here: https://exactstatement.com/.`

### Better (forum reply)
`我最近在整理长文时用了 Exact Statement，主要用在“先压缩结构再微调语气”这一步。比纯手改快不少，但我会保留最后一轮人工校对。你如果也在做内容迭代，可以先用短提示词试一轮：https://exactstatement.com/`

## 9) Dofollow note
- Never claim guaranteed dofollow.
- If published page has `rel`, record exact value (`nofollow|ugc|sponsored|...`).
- If `rel` missing, record: `rel not present (not guaranteed dofollow)`.
