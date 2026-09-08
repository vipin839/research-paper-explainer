# Research Paper Explainer — Complete Technical Documentation

Everything about this project, written so you can explain any part of it under
questioning. Read top to bottom; it follows the path a request actually takes.

**Last verified against the code on 8 September 2026.**

---

## Quick reference — memorise this much

| Question | Answer |
|---|---|
| What is it? | A web app that rewrites dense scientific abstracts into plain language at three reading levels |
| Which model? | `nvidia/nemotron-3-super-120b-a12b` |
| Where does it run? | NVIDIA's hosted API at `integrate.api.nvidia.com` |
| Training or fine-tuning? | **None.** Inference-only |
| Why does the `openai` package work? | NVIDIA's endpoint is OpenAI-API-compatible |
| UI framework | Gradio 6.26 |
| Hosting | Azure App Service (Linux, B1), auto-deploys from GitHub |
| Input limit | 5,000 characters (this tool explains abstracts, not whole papers) |
| Data collected | None. Only an anonymous hashed unique-visitor count |

---

## 1. The problem it solves

Students lose hours decoding vocabulary before reaching the actual finding of a
paper. Existing summarisers compress text but keep the same specialist
vocabulary, so the reader is no better off.

This tool does something different: it **rewrites at a chosen reading level** and
handles jargon differently at each level. At Beginner it removes technical
vocabulary entirely; at Student it keeps the terms and defines them, so the
reader learns them; at Advanced it preserves all terminology and simplifies only
the sentence structure.

That per-level treatment of vocabulary is the actual idea. Everything else is
plumbing.

---

## 2. Architecture

```
Browser (Gradio UI)
      |
      |  paste abstract + choose reading level, press Explain
      v
app.py  ->  explain()             <- runs on the Azure server
      |
      |  builds system prompt = BASE_RULES + level instructions
      |  wraps your text in --- TEXT START/END --- markers
      v
openai Python client
      |
      |  HTTPS to https://integrate.api.nvidia.com/v1
      v
NVIDIA hosted inference
   nvidia/nemotron-3-super-120b-a12b
      |
      |  streams tokens back
      v
explain() yields partial text  ->  Gradio repaints the page live
```

The Azure server does almost no computation. It formats a prompt, forwards it,
and relays the reply. The 120-billion-parameter model runs on NVIDIA's hardware.

---

## 3. Files

| File | Purpose |
|---|---|
| `app.py` | The entire application — config, prompts, API call, error handling, UI |
| `requirements.txt` | `gradio==6.26.0`, `openai==3.8.0` |
| `README.md` | Project overview (its YAML header also configures Hugging Face Spaces) |
| `DOCUMENTATION.md` | This file |
| `AZURE_DEPLOY.md` | Step-by-step Azure deployment guide |
| `run.ps1` | Local launcher; prompts for the API key if unset |
| `startup.sh` | Azure startup command reference |
| `.github/workflows/` | GitHub Actions workflow that deploys to Azure on every push |

---

## 4. The model, and why this one

### 4.1 How it was chosen

Not by reading documentation — by testing every Nemotron model the account could
actually reach:

| Model | Result |
|---|---|
| `nvidia/nemotron-3-super-120b-a12b` | **Chosen.** ~2s to first token, clean output |
| `nvidia/nemotron-3-ultra-550b-a55b` | Works, larger and slower |
| `nvidia/nemotron-3.5-lightning-30b-a3b` | **Rejected** — degenerates into repeated characters when reasoning is disabled |
| `mistralai/mistral-nemotron` | Works, alternative |
| `nvidia/llama-3.1-nemotron-70b-instruct` | 404 — not available to this account |
| `nvidia/nemotron-nano-9b-v2` | **No longer exists** in NVIDIA's catalogue |

That last row matters: the model name in most tutorials and older code snippets
is retired. The live model list is the source of truth.

### 4.2 The reasoning-mode discovery

**This is the single most interesting technical detail in the project.**

Nemotron 3 is a **reasoning model**. Before answering it writes out a private
train of thought. Left on, that thinking appears in the visible answer, so users
would read:

> "Okay, the user has given me a scientific statement about CRISPR-Cas9... Hmm,
> this seems like a student who..."

instead of their explanation. It is switched off with:

```python
NO_THINKING = {"chat_template_kwargs": {"thinking": False}}
```

passed through `extra_body`, because the OpenAI client has no built-in parameter
for a vendor-specific flag. This was found by testing, not from documentation.

### 4.3 Why the `openai` package talks to an NVIDIA model

NVIDIA implements the **same API shape as OpenAI** — same request format, same
response format, same streaming protocol. So the standard client works by
pointing it at a different address:

```python
client = OpenAI(base_url="https://integrate.api.nvidia.com/v1", api_key=api_key)
```

No custom HTTP code, and switching providers later is a one-line change. If a
judge asks one technical question, this is the best thing to be able to explain.

### 4.4 Context limit — measured, not assumed

The API does not publish a context length, so it was tested directly:

| Input size | Result |
|---|---|
| 12,000 chars | OK — 1,764 prompt tokens |
| 48,000 chars | OK — 6,993 tokens |
| 200,000 chars | OK — 29,055 tokens, 10.7s |
| 400,000 chars | OK — 58,088 tokens, 3.3s |

The model was never the constraint. The app's **5,000-character limit is a
product decision** — it comfortably fits a long abstract and keeps answers near two seconds. Longer inputs work but get slow, and a 4–6 sentence summary of an entire
paper is not very useful.

---

## 5. The prompt — where the quality comes from

Split into two parts, joined in `build_messages()`.

### 5.1 `BASE_RULES` — applies to every request

Nine numbered rules, each preventing a specific failure:

| Rule | Failure it prevents |
|---|---|
| 1. Use only the given text | Inventing findings the paper never reported |
| 2. Plain, direct language | Swapping jargon for different jargon |
| 3. Define terms in parentheses immediately | Reader having to look things up |
| 4. Exactly 4–6 sentences | Rambling, or a useless one-liner |
| 5. Last sentence = why it matters | A summary with no "so what" |
| 6. One paragraph, no bullets | Output that looks like a slide |
| 7. Never mention the instructions | The model narrating its own task |
| 2a. Never copy the source verbatim | Echoing the abstract back instead of rewriting |
| 8. **Refuse rather than invent** | Confabulating science from thin input |
| 9. Rule 8 outranks everything else | The model explaining anyway |

**Rule 1 and rule 8 are the ones to mention to judges.** Fabrication is the real
risk when an AI explains research, and the prompt is explicitly built against it.

Rule 8 is tested: vague one-liners, chit-chat, random words and a shopping list
all get refused with a fixed sentence rather than an invented explanation.

Your text is wrapped in `--- TEXT START --- / --- TEXT END ---` markers so the
model can tell your content apart from the instructions.

### 5.2 `LEVELS` — appended per reading level

The three levels differ **substantively**, not just in word choice:

| | Beginner | Student | Advanced |
|---|---|---|---|
| Technical terms | Avoided entirely | Kept **and defined** | Kept, undefined |
| Statistics | Converted to plain comparisons | Kept and explained | Kept exactly |
| Analogy | Required, one carried through | Not used | Forbidden |
| What is simplified | Everything | Vocabulary | **Only structure** |
| Assumed knowledge | None at all | First-year science | Graduate literacy |

Advanced is the subtle one: it does **not** simplify the science. It preserves
every term, metric and caveat, and simplifies only sentence structure and
ordering — putting the main finding first and breaking up dense clauses.

**Verified on the same abstract:**

- Beginner never writes "TP53", drops `p<0.001`, says "more than three times as fast"
- Advanced keeps `TP53`, `CDKN1A`, `MKI67`, `p<0.001` and "G1/S checkpoint"
- Word overlap between Beginner and Advanced: **11%**

---

## 6. Walking through `app.py`

### 6.1 The API call

```python
stream = client.chat.completions.create(
    model=MODEL_ID,
    messages=build_messages(text, level),
    temperature=0.3,
    top_p=0.95,
    max_tokens=700,
    stream=True,
    extra_body=NO_THINKING,
)
```

- **`temperature=0.3`** — low, because this is explanation, not creative writing.
  The same abstract should give a consistent answer.
- **`max_tokens=700`** — roughly 500 words; 4–6 sentences fits with headroom.
- **`stream=True`** — the reply arrives in pieces as generated. This is why text
  appears live rather than all at once.

### 6.2 Streaming, and why `explain()` is a generator

`explain()` uses `yield` instead of `return`, making it a **generator** — a
function that hands back many values over time. Gradio repaints the page on each
`yield`.

```python
buf = ""
for chunk in stream:
    piece = chunk.choices[0].delta.content
    if piece:
        buf += piece
        yield scrub(buf), busy      # page updates here, mid-generation
```

Each iteration appends the newest fragment and yields the whole accumulated text,
producing the typewriter effect. The user sees progress in about a second instead
of staring at a frozen screen.

### 6.3 Automatic retry — five attempts

NVIDIA's shared endpoint intermittently returns **"Service temporarily
overloaded" (503)**. In testing it hit roughly one call in three under load, and
three quick attempts were **not enough** — requests still failed with no output.

```python
MAX_ATTEMPTS = 5
RETRY_DELAYS = [1.5, 3.0, 5.0, 8.0]
```

Transient failures (overloaded, 429, 502/503/504, timeout, empty reply) are
retried with a growing backoff, showing "The service is busy — retrying (n/5)".
Permanent failures (bad key, missing model) stop immediately, because retrying
cannot help.

**One subtlety worth knowing:** the `streamed` flag. If text has already started
appearing and the connection then drops, it does **not** retry — restarting would
print the explanation twice. It only retries a request that produced nothing.

### 6.3a Intermittent 404s and the fallback chain

NVIDIA's endpoint has been observed returning **404 for a model that is
definitely in the catalogue** - in one measurement, 8 of 10 calls failed this
way while `models.list()` still listed the model. It is an infrastructure
hiccup, not a missing model.

This matters because a 404 is normally a *permanent* error, so the original
code failed instantly without retrying. Two changes fixed it:

1. **404 is now treated as retryable**, alongside 429/503/timeouts.
2. **A fallback chain**: the app tries the primary model three times, then
   falls back to `nemotron-3-ultra-550b-a55b`, then `mistral-nemotron`.

```python
plan = [MODEL_ID] * 3 + FALLBACK_MODELS
```

Measured after the fix: **6 of 6 requests succeeded**, all on the primary model,
with the retries absorbing the 404s invisibly. Before the fix the same
conditions produced roughly an 80% failure rate.

The status line names whichever model actually answered, so if a fallback is
ever used you can see it.

### 6.3b The verbatim-copy bug

On the physics abstract, the model would sometimes **echo the input back word
for word** instead of explaining it - a 700-character verbatim run, in 3 of 4
runs. Adding a prompt rule against copying did not help.

The fix was structural: move the instruction **after** the source text in the
user message. With the instruction first, the model treated the abstract as
something to continue; with it last, the task is the most recent thing in
context. Result: 0 of 5 runs copied, verbatim overlap down from 700 characters
to 11.

`longest_verbatim_run()` still runs on every answer and logs a warning if the
overlap exceeds 150 characters, so a regression would be visible in the logs.

### 6.4 Error handling — different messages for you and for visitors

```python
HOSTED = bool(os.environ.get("WEBSITE_SITE_NAME") or os.environ.get("SPACE_ID"))
```

On a public deployment, a visitor is not the operator. Telling them to run
`$env:NVIDIA_API_KEY = "nvapi-..."` in PowerShell would leak an internal
environment variable name and confuse them. So:

| Situation | Local message | Public message |
|---|---|---|
| No API key | How to set it, with the exact command | "This tool is temporarily unavailable" |
| Key rejected (403) | Get a fresh key at build.nvidia.com | Same generic message |
| Model 404 | Names the model, says to change `MODEL_ID` | Same generic message |
| Unexpected error | Exception type and message | Same generic message |
| Busy / rate limited | "The service is busy" | Same |
| No connection | "Check your connection" | Same |

Full detail always goes to the **server log** via `_log()`, never to the UI.

**Detail worth remembering:** NVIDIA returns **403**, not 401, for a bad key.
Found by testing with a fake key.

### 6.5 Input validation

| Input | Response |
|---|---|
| Empty | "Paste an abstract above, then press Explain." |
| Under 40 characters | "That's very short. Paste at least a couple of sentences." |
| Over 5,000 characters | Tells you the count and asks for just the abstract |
| Non-English, emoji, code, special characters | Handled — no crash, no traceback |

Tested with Hindi text, code snippets, `<script>` tags, shell metacharacters and
emoji. None crash the app or produce a Python traceback.

### 6.6 The interface

Gradio builds a web page from Python objects. Two tabs:

- **Explain** — the tool
- **About** — full documentation inside the app

```python
go.click(explain, inputs=[inp, level], outputs=[out, status])
```

Reads as: *when Explain is clicked, call `explain()` with the textbox and radio
values, and put the two returned values into the output box and status line.*

**Four examples**, deliberately spanning fields so the tool visibly is not tuned
to one topic: CRISPR cell biology, a GLP-1 clinical trial, an IBD microbiome
study, and **graphene quantum Hall physics**.

### 6.7 The copy button

Gradio 6 **removed `show_copy_button`** from both Textbox and Markdown, so
copying is done in the browser. The handler tries the async clipboard API, and
falls back to `document.execCommand('copy')` if that fails — which happens on
non-HTTPS origins or when the document is not focused. It flashes "Copied",
"Nothing to copy", or "Select and press Ctrl+C" accordingly.

### 6.8 The character counter

Shows `n / 5,000 characters`, turning amber past 90%. The textbox also carries
`max_length`, so the browser enforces the cap before anything is sent.

**A bug worth remembering:** Gradio sets the textarea value *programmatically*
when you click an example or Clear, which fires **no `input` event**, so a plain
event listener misses it and the count goes stale. The counter therefore polls
every 400ms as well as listening.

### 6.9 Dark mode — a real bug that was fixed

The output panel originally hardcoded a near-white background. In dark mode
Gradio's text is near-white too, giving white on white — a contrast ratio of
**1.04:1**, effectively invisible. The CSS now uses Gradio's own variables
(`var(--body-text-color)`, `var(--background-fill-secondary)`), which resolve
correctly in either theme.

General lesson: never hardcode one half of a foreground/background pair.

---

## 7. Privacy, security and trust

### 7.1 What the app collects

**Nothing about you.** No accounts, no sign-in, no passwords, no personal or
financial fields. The text you paste is not stored, and explanations are not kept.

The only record is an anonymous **unique visitor count**.

### 7.2 How the visitor counter protects privacy

Raw IP addresses are **never written to disk**. Each IP is combined with a fixed
salt and hashed with SHA-256; only the first 16 characters of the hash are stored.
The count is exact, the file contains no personal data, and the original IPs
cannot be recovered.

**Finding the real IP takes care behind a proxy.** On Azure the app never sees
the visitor directly — requests arrive through Azure's front end, so
`request.client.host` is Azure's own address, identical for everyone. The real
client IP is the first entry in the `X-Forwarded-For` header. Azure also appends
a source port (`1.2.3.4:51234`) that changes every request, so the port is
stripped before hashing. **Without that step one visitor would count dozens of
times.**

Storage: `/home/data/visitors.json` on Azure (survives restarts and redeploys),
beside `app.py` locally. Writes are guarded by a lock, and every file operation
is wrapped in `try/except` — a counter that cannot be read must never take the
app down.

### 7.3 Security audit results

Audited both statically and by inspecting the live deployed page:

| Check | Result |
|---|---|
| Login / password / PII fields | **None.** 0 forms, 0 password fields |
| Redirects, iframes, hidden navigation | **None** |
| External resources loaded by the live page | **Zero** — every asset same-origin |
| Analytics / tracking / advertising | **None** (see below) |
| API key hardcoded anywhere | **No** — environment variable only |
| Key value printed to logs | **No** |

**One genuine finding:** Gradio ships usage telemetry that posts to
`api.gradio.app` on startup, **enabled by default**. Since this app collects
nothing about its visitors, it is switched off:

```python
os.environ["GRADIO_ANALYTICS_ENABLED"] = "False"   # before importing gradio
```

It must be set **before** `import gradio` to take effect.

### 7.4 The Safe Browsing flag

The Azure URL was flagged by Google Safe Browsing as possible phishing. The audit
above shows there is nothing in the app to cause it — no forms, no external
scripts, no redirects. It is **domain reputation** on the shared
`azurewebsites.net` host, which is heavily abused by real phishing sites, and
random-suffix subdomains get caught in the blast radius.

No code change can clear it. The fixes are: serve from a different domain
(Hugging Face Spaces), and report the false positive through the warning page so
Google re-reviews.

---

## 8. Deployment

### 8.1 How it reaches Azure

Every push to `main` triggers a GitHub Actions workflow that builds the app and
deploys it to Azure App Service. Roughly 6 minutes.

### 8.2 The 409 Conflict problem

Azure App Service allows **one deployment at a time**. Pushing several commits in
quick succession queues overlapping runs, and the later ones fail with
`Conflict (CODE: 409)`.

Fixed with a GitHub Actions concurrency group that queues runs instead of
overlapping them:

```yaml
concurrency:
  group: azure-deploy-${{ github.ref }}
  cancel-in-progress: false
```

Practical habit: batch changes into one commit rather than pushing repeatedly.

### 8.3 Host detection

`app.py` detects its environment and adapts:

| Environment | Detected by | Behaviour |
|---|---|---|
| Azure App Service | `WEBSITE_SITE_NAME` | Binds `0.0.0.0` on the injected `PORT` |
| Hugging Face Spaces | `SPACE_ID` | Binds `0.0.0.0:7860` |
| Local | neither | Binds `127.0.0.1:7860`, opens a browser |

### 8.4 Running locally

```powershell
cd "F:\Claude Folder\gtc-paper-explainer"
$env:NVIDIA_API_KEY = "nvapi-your-key-here"
.\.venv\Scripts\python.exe app.py
```

Opens at <http://127.0.0.1:7860>. Force light mode (better on video) with
<http://127.0.0.1:7860/?__theme=light>.

---

## 9. Gradio 6 gotchas encountered

Useful if anything breaks and you need to fix it live:

| Gotcha | Consequence |
|---|---|
| `theme` and `css` moved from `Blocks()` to `launch()` | Styling silently ignored |
| `show_api` removed from `launch()` | `TypeError` on startup |
| `show_copy_button` removed from Textbox and Markdown | Had to write a JS copy button |
| Tab contents render **lazily** | About panel is absent from the DOM until first clicked — normal, not a bug |
| Examples set values programmatically | No `input` event fires |

---

## 10. Known limitations — say these plainly if asked

Naming these accurately is a strength. It shows you understand what you built.

- **The 4–6 sentence rule is an instruction, not a hard constraint.** It held on
  every test, but a language model can drift.
- **Fabrication is reduced by the prompt, not eliminated.** Refusal is reliable on
  obvious nonsense; a plausible-sounding but fake abstract would still be explained.
  Always check against the original paper.
- **Input is capped at 5,000 characters** - a long structured abstract is about 2,000, so this leaves headroom while keeping answers near two seconds.
- **NVIDIA's endpoint can be busy.** Five retries make failure unlikely, not impossible.
- **Text only** — no PDF upload, no figures, no references, no equations as images.
- **English-oriented.** Other languages do not crash it, but quality is untested.

---

## 11. Likely judge questions, with short answers

**"Did you train or fine-tune anything?"**
No. Inference-only. The model runs on NVIDIA's servers; my app formats a prompt
and relays the response.

**"Why NVIDIA Nemotron specifically?"**
I tested every Nemotron model my account could reach. This one answered in about
two seconds with clean output. A smaller variant degraded badly when I disabled
reasoning mode, and several catalogue entries returned 404.

**"How do you stop it making things up?"**
Two prompt rules. Rule 1 restricts it to the pasted text only. Rule 8 tells it to
refuse rather than invent, and rule 9 makes that outrank everything else. I tested
it with nonsense input — random words, chit-chat, a shopping list — and it refuses
instead of confabulating.

**"What's the hardest technical problem you hit?"**
Nemotron 3 is a reasoning model, so by default it streams its private thinking
into the visible answer. Disabling that needed a vendor-specific flag passed
through `extra_body`, which I found by testing rather than from documentation.

**"Why does an OpenAI library talk to an NVIDIA model?"**
NVIDIA's endpoint implements the same API shape, so the standard client works by
pointing it at a different base URL. It also means switching providers is a
one-line change.

**"What data do you collect?"**
None. No accounts, no stored text. The only record is a unique visitor count,
stored as a salted SHA-256 hash so no IP address is ever written to disk.

**"What would you do with more time?"**
PDF upload, a side-by-side view of all three levels at once, and a citation check
that flags claims in the explanation not traceable to a sentence in the source.
