# Research Paper Explainer — How It Works

A walkthrough of the whole project, written so you can explain any part of it if a
judge asks. Read top to bottom; it follows the path a request actually takes.

---

## 1. What the app does, in one paragraph

You paste a scientific abstract and pick a reading level. The app wraps your text in
a carefully written instruction set, sends it to an NVIDIA Nemotron model running on
NVIDIA's servers, and streams the reply back into the page word by word. Nothing is
trained, downloaded, or stored. It is a thin, well-designed layer between a text box
and a large language model.

---

## 2. The shape of the system

```
Browser (Gradio UI)
      |
      |  you type an abstract + pick a level, press Explain
      v
app.py  ->  explain()          <- runs on your machine
      |
      |  builds a system prompt + user message
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
explain() yields partial text  ->  Gradio updates the page live
```

Only one file matters: `app.py`. Everything else is setup, docs, or launcher.

---

## 3. File by file

| File | What it is |
|---|---|
| `app.py` | The entire application: config, prompts, API call, error handling, UI |
| `requirements.txt` | The two libraries needed, pinned to versions that were tested |
| `run.ps1` | Convenience launcher; asks for your API key if it isn't set |
| `README.md` | Short project overview (also configures Hugging Face Spaces) |
| `DOCUMENTATION.md` | This file |
| `.gitignore` | Stops the virtual environment and any key files reaching GitHub |
| `.venv/` | The isolated Python environment with the libraries installed |

---

## 4. Walking through `app.py`

### 4.1 Configuration block

```python
MODEL_ID = "nvidia/nemotron-3-super-120b-a12b"
BASE_URL = "https://integrate.api.nvidia.com/v1"
NO_THINKING = {"chat_template_kwargs": {"thinking": False}}
```

**`MODEL_ID`** — the model doing the work. Change this one string to swap models.

**`BASE_URL`** — NVIDIA hosts models behind an endpoint that speaks the *same
protocol as OpenAI's API*. That is why the `openai` Python package works here without
modification: you point it at NVIDIA's address instead of OpenAI's, and everything
else is identical. This is the single most useful technical fact about the project.

**`NO_THINKING`** — the important one. Nemotron 3 is a **reasoning model**: before
answering it writes out a private train of thought. Left on, that thinking appears in
the answer, so the user sees:

> "Okay, the user has given me a scientific statement about CRISPR-Cas9... Hmm, this
> seems like a student who..."

This flag switches reasoning off so only the finished explanation is returned. It was
found by testing, not from documentation. Without it the demo looks broken.

### 4.2 The prompt

The prompt is where the quality actually comes from. It is split in two.

**`BASE_RULES`** — constant, applies to every request. Eight numbered rules, each
solving a specific failure:

| Rule | The failure it prevents |
|---|---|
| 1. Use only the given text | The model inventing findings the paper never reported |
| 2. Plain, short sentences | Jargon being swapped for different jargon |
| 3. Define terms in parentheses immediately | Reader having to look things up elsewhere |
| 4. Exactly 4–6 sentences | Rambling, or a one-line answer that teaches nothing |
| 5. Last sentence = why it matters | A summary with no "so what" |
| 6. One paragraph, no bullets | Output that looks like a slide instead of an explanation |
| 7. Never mention the instructions | The model narrating its own task |
| 8. Reject non-scientific input | Nonsense output when someone pastes a recipe |

Rule 1 is the one to mention to judges. Fabrication is the real risk when an AI
explains research, and the prompt is explicitly built against it.

**`LEVELS`** — a different audience description added depending on the radio button:

- **Beginner** — no science background, roughly 15 years old, analogies allowed
- **Student** — undergraduate; knows general biology, not this subfield
- **Advanced** — a researcher from a *different* field; keep precision, unpack shorthand

The two pieces are joined in `build_messages()`, and your abstract is wrapped in
`--- TEXT START --- / --- TEXT END ---` markers so the model can tell your text apart
from the instructions.

### 4.3 The API call

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

- **`temperature=0.3`** — controls randomness. Low, because this is explanation, not
  creative writing; you want the same abstract to give a consistent answer.
- **`max_tokens=700`** — a ceiling on reply length. Roughly 500 words; 4–6 sentences
  fits comfortably with headroom.
- **`stream=True`** — the reply arrives in pieces as it is generated, instead of all
  at once at the end. This is why text appears live on screen.
- **`extra_body`** — passes the NVIDIA-specific reasoning switch through the OpenAI
  client, which has no built-in parameter for it.

### 4.4 Streaming, and why `explain()` is a generator

`explain()` uses `yield` instead of `return`, which makes it a **generator** — a
function that hands back many values over time rather than one at the end. Gradio
understands generators and repaints the page on each `yield`.

```python
buf = ""
for chunk in stream:
    piece = chunk.choices[0].delta.content
    if piece:
        buf += piece
        yield scrub(buf), busy      # page updates here, mid-generation
```

Each loop appends the newest fragment to `buf` and yields the whole accumulated text.
That produces the typewriter effect. It also means the user sees progress within
about a second instead of staring at a frozen screen for five.

### 4.5 Automatic retry

NVIDIA's public endpoint intermittently replies "Service temporarily overloaded" —
during testing it hit roughly one call in three. Unhandled, that shows an error at the
worst possible moment.

The whole request sits inside `for attempt in range(MAX_ATTEMPTS)`. On a *transient*
failure (overloaded, 429, 502/503/504, timeout, empty reply) it waits and tries again,
up to three attempts, showing "NVIDIA's server is busy — retrying". On a *permanent*
failure (bad key, missing model) it stops immediately, because retrying cannot help.

One subtlety: the `streamed` flag. If text has already started appearing and the
connection then drops, it does **not** retry — restarting would print the explanation
twice. It only retries a request that produced nothing.

### 4.6 Error handling

Every failure is translated into a sentence telling you what to do:

| Situation | Message |
|---|---|
| No `NVIDIA_API_KEY` set | How to set it, with the PowerShell command |
| Key doesn't start with `nvapi-` | Says the format is wrong before wasting a call |
| Key rejected (401 or 403) | Get a fresh key at build.nvidia.com |
| Model unavailable (404) | Name the model and say to change `MODEL_ID` |
| Busy / rate limited | Press Explain to try again |
| No internet | Check your connection |

NVIDIA returns **403**, not 401, for a bad key — found by testing with a fake key.

### 4.7 The interface

Gradio builds a web page from Python objects. `gr.Blocks` is the container; inside it
`gr.Textbox`, `gr.Radio`, `gr.Button` and `gr.Markdown` become real HTML elements.

```python
go.click(explain, inputs=[inp, level], outputs=[out, status])
```

Read as: *when the Explain button is clicked, call `explain()` with the textbox and
radio values, and put the two returned values into the output box and the status
line.* `inp.submit(...)` does the same on Enter.

`gr.Examples` gives the three preset abstracts. Clicking one fills the textbox **and**
sets the matching reading level, because both are listed in its `inputs`.

**The dark mode fix.** The output panel originally hardcoded a near-white background.
In dark mode Gradio's text is near-white too, giving white on white — a contrast ratio
of 1.04:1, effectively invisible. The CSS now uses Gradio's own variables
(`var(--body-text-color)`, `var(--background-fill-secondary)`), which resolve to the
right values in either theme. This is worth remembering generally: never hardcode one
colour of a foreground/background pair.

---

## 5. How your API key is handled

```python
api_key = os.environ.get("NVIDIA_API_KEY")
```

The key is read from an **environment variable** — a value that lives in your terminal
session, not in any file. The key is never written into `app.py`, so the source can be
shared or pushed to GitHub safely.

`.gitignore` additionally blocks `.env` and `key.txt` in case you create them later.

Setting it lasts only for the terminal window you typed it in. Open a new terminal and
you must set it again — that's the trade-off for not storing a secret on disk.

---

## 6. Why these technical choices

**Why a hosted API instead of running the model locally?** A 120-billion-parameter
model needs far more GPU memory than a laptop has. NVIDIA runs it; you send text and
get text back. It also makes the project genuinely inference-only.

**Why the `openai` package for an NVIDIA model?** NVIDIA implements the same API
shape. Using the standard client means no hand-written HTTP, and swapping providers
later is a one-line change.

**Why Gradio?** It turns Python functions into a web UI with no HTML or JavaScript,
supports streaming generators natively, and can produce a public link.

**Why this specific model?** Tested against every Nemotron the account could reach.
`nemotron-3-super-120b-a12b` answered in about two seconds with clean output.
`nemotron-3.5-lightning-30b-a3b` degenerated into repeated characters with reasoning
disabled. Several models listed in the catalogue returned 404 for this account.

**Why not `nemotron-nano-9b-v2`?** It is no longer in NVIDIA's catalogue. The live
model list is the source of truth, not older code snippets.

---

## 7. Running it

```powershell
cd "F:\Claude Folder\gtc-paper-explainer"
$env:NVIDIA_API_KEY = "nvapi-your-key-here"
.\.venv\Scripts\python.exe app.py
```

Opens automatically at <http://127.0.0.1:7860>. Stop it with `Ctrl+C`.

Force light mode (better on video): <http://127.0.0.1:7860/?__theme=light>

---

## 8. Known limits — say these plainly if asked

- The 4–6 sentence rule is an *instruction*, not a hard constraint. It held on every
  test, but a language model can drift.
- Fabrication is reduced by the prompt, not eliminated. Always check against the paper.
- Very long abstracts are capped at 12,000 characters.
- NVIDIA's free endpoint is rate limited and occasionally busy; retry handles the
  common case.
- It reads pasted text only — no PDF upload, no figures, no references.

Naming these accurately is a strength, not a weakness. It shows you understand what
you built.
