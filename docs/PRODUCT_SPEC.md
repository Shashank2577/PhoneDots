# PhoneDots — Product Spec

**An AI agent that runs entirely on your phone.**
Gemma is the brain. Desert Ant's specialist models and the phone's own APIs are its hands.
Skills are the way new abilities get added. No cloud and no account, and it works in airplane mode.

---

## 1. The idea in one picture

```
 ┌──────────────────────────── SURFACES ─────────────────────────────┐
 │ Chat · Voice mode · Live camera · Share sheet · Widgets ·          │
 │ Siri/App Intents · Android Intents · Notifications · Automations   │
 └───────────────────────────────┬────────────────────────────────────┘
                                 ▼
 ┌──────────────────────────── AGENT CORE ───────────────────────────┐
 │ Planner: Gemma 4 (E2B / E4B), with thinking mode                  │
 │ Fast router: FunctionGemma 270M (device actions in <300 ms)       │
 │ Tool loop: plan → call skill → observe → repeat → answer          │
 │ Constrained JSON decoding · permission gates · trace viewer       │
 └───────┬───────────────┬────────────────┬──────────────┬───────────┘
         ▼               ▼                ▼              ▼
   MODEL SKILLS     DEVICE SKILLS    KNOWLEDGE SKILLS   UI SKILLS
   (Desert Ant,     (calendar,       (your docs, notes, (cards, maps,
    Gemma vision/    contacts, alarms, photos, offline   charts, tables,
    audio)           files, sensors)   Wikipedia, memory) forms)
         └───────────────┴───────┬────────┴──────────────┘
                                 ▼
 ┌──────────────────────────── RUNTIME ──────────────────────────────┐
 │ LiteRT-LM (Gemma 4, FunctionGemma, EmbeddingGemma)                 │
 │ Desert Ant SDK: Core ML on Apple devices, LiteRT on Android        │
 │ Android AICore (optional system Gemma) · On-device vector store    │
 │ Model registry + download manager + benchmark                      │
 └────────────────────────────────────────────────────────────────────┘
```

---

## 2. Models: who does what

### Gemma family (the brain), via LiteRT-LM
| Model | Role in the app |
|---|---|
| **Gemma 4 E2B** | Default planner/chat model. Text, image and audio in. Thinking mode. Fast on mid-range phones. |
| **Gemma 4 E4B** | "Smart mode" on high-end phones. Better reasoning and longer multi-step tool chains. |
| **FunctionGemma 270M** | Always-loaded, very fast intent → function-call router for phone actions ("torch on", "remind me at 6"). Can be fine-tuned per skill pack. |
| **EmbeddingGemma** | Embeds text, images and audio for semantic search, memory, RAG and photo search. Matryoshka truncation keeps the index small. |
| **Gemma 3 270M** (fine-tunes) | Tiny task-specific models that users or the community train for a single job (e.g. a commit-message writer). Loaded as skills. |
| Domain Gemmas (e.g. MedGemma, ShieldGemma) | Optional downloadable packs (domain Q&A, safety classification), each with clear disclaimers. |

### Desert Ant (the specialists): one model per task
| Model | Skill it powers |
|---|---|
| **Voz** | `transcribe`: 10 min of audio in about 2 s on an iPhone, with word timestamps |
| **Who** | `diarize`: who said what |
| **Align** | `align_transcript`: word timing for any transcript (subtitles, karaoke) |
| **Uhm** | `remove_fillers`: strip "um/uh" from transcript and audio |
| **Clear** | `enhance_speech`: denoise recordings |
| **Ear** | `detect_spoken_language` |
| **Tongue** | `detect_text_language` (from 3 words) |
| **Redact** | `redact_pii`: privacy filter before anything leaves the phone |
| **Schemer** | `extract_json`: typed data from text (receipts, emails → events) |
| **Gist** | `topics_and_tags` |
| **Title** | `suggest_title` |
| **Emo** | `suggest_emoji` |
| **Eye** | `classify_image` / `rank_aesthetics`: tag photos, pick the best shot |
| **Face** | `match_faces`: on-device people albums |
| **Moderator** | `moderate_image` (NSFW flags) |
| **Toxic** | `classify_toxicity` |
| **Clips** | `pick_highlights`: best moments of a video for shorts |
| **Shapes** | `clean_sketch`: rough drawing → clean shapes |

> **Platform note (desert-ant-core 4.2.1):** Voz, Who, Ear, Clear, Redact, Tongue, Emo, Gist, Eye, Moderator and Shapes run natively on both Android (`ai.desertant:*`) and iOS (Core ML). Uhm, Align, Title and Clips are Apple-only. Face, Schemer and Toxic are in closed beta with no SDK, so the app covers those jobs with Gemma (`extract_fields`, `check_tone`). Licence: free up to 100k monthly active devices.

---

## 3. The Skill system

This is the heart of the product. Everything the agent can do is a **skill**: the Desert Ant models, phone actions, search and UI cards.

### 3.1 Skill manifest
```yaml
id: meeting.transcribe
name: Transcribe meeting
description: Turn an audio recording into a speaker-labelled transcript.
kind: model            # model | device | knowledge | ui | composite | remote-script
inputs:
  audio: { type: audio, required: true }
  speakers: { type: integer, required: false }
outputs:
  transcript: { type: transcript }
requires_models: [desertant.voz, desertant.who]
permissions: [microphone_files]
platforms: { ios: native, android: onnx }
cost_hint: { latency_ms: 2000, ram_mb: 600 }
confirm: never         # never | first_time | always (always for anything that sends, buys or deletes)
```
- Gemma sees only `name`, `description` and the input schema, and calls the skill with constrained JSON.
- `requires_models` triggers a just-in-time download prompt.
- `confirm` drives the permission gate. Anything that sends, deletes or spends money always needs a tap.

### 3.2 Skill kinds
1. **Model skills**: wrap one model call (all of Desert Ant, plus Gemma vision/audio).
2. **Device skills**: native OS APIs.
3. **Knowledge skills**: query local indexes.
4. **UI skills**: return a rendered card (map, chart, table, form, timeline) instead of text.
5. **Composite skills (Recipes)**: a saved chain of skills, either authored by the user or built by the agent ("save this as a recipe").
6. **Community skills**: loaded from a URL, like Edge Gallery. They are declarative manifests plus sandboxed JS, with no native code, and permissions are asked at install time.

### 3.3 Skill catalog (v1 target ≈ 60 skills)

**Voice & audio**
- transcribe · diarize · align_transcript · remove_fillers · enhance_speech · detect_spoken_language
- meeting_minutes (composite): transcribe → diarize → summarize → action items → calendar/todo
- voice_memo_to_note · subtitle_video (SRT export) · podcast_chapters · translate_speech (Gemma)

**Vision & camera**
- ask_image (Gemma 4 vision) · classify_image · rank_aesthetics · best_shot_picker
- match_faces / people_albums · moderate_image · clean_sketch
- read_document (OCR via Gemma vision) · receipt_to_expense (vision → Schemer)
- live_camera_describe (accessibility) · translate_sign/menu · plant/food/object ID

**Text & writing**
- summarize · rewrite (tone) · translate · proofread · reply_suggestions
- suggest_title · topics_and_tags · suggest_emoji · detect_text_language
- extract_json (Schemer): emails → events, invoices → fields, contacts from signatures
- redact_pii · classify_toxicity · draft_message (opens a composer, never auto-sends)

**Phone actions** (FunctionGemma router)
- flashlight · alarm/timer · reminder · calendar create/query · contacts lookup
- open app / deep link · settings toggles (Wi-Fi, DND, brightness) · media control
- send SMS/email (draft + confirm) · call (confirm) · navigation intent
- clipboard read/write · files search/move · battery/storage status · location (on request)

**Knowledge & memory**
- search_my_files (PDF, notes, docs) with EmbeddingGemma RAG
- search_my_photos ("receipts from March", "dog on the beach") using image embeddings + Eye tags
- personal_memory: remember/forget facts with the user's consent; the user can see and edit all of them
- offline_wikipedia (downloadable packs) · dictionary · unit/currency (cached rates) · calculator

**UI / output cards**
- map_card (offline tiles) · chart_card · table_card · timeline_card · checklist_card
- summary_card (shareable image) · form_card (the agent asks for missing fields)

**Creator tools**
- shorts_from_video: Clips → Align → captions → title/emoji/tags
- post_package: title + description + tags + emoji + moderation check
- clean_audio_export: Clear + Uhm

---

## 4. Agent core

- **Two-tier routing.** FunctionGemma 270M handles simple single-action intents in well under a second. Anything multi-step, ambiguous or multimodal escalates to Gemma 4.
- **Tool loop.** Plan → call → observe → reflect, with a max step budget (default 8). Skill outputs are summarised before they go back into context to save tokens.
- **Constrained decoding.** LiteRT-LM tool use with JSON-schema constraints, so no malformed calls.
- **Thinking mode.** Toggleable. The UI shows the reasoning collapsed.
- **Trace view.** Every run shows each skill called, its inputs and outputs, latency and the model used. It is exportable for debugging community skills.
- **Safety.** A permission gate per skill, confirmation for side-effecting actions, Redact before share/export, and an optional ShieldGemma/Toxic input filter.
- **Resource governor.** Picks E2B or E4B by device RAM and thermal state, unloads idle models, and queues heavy jobs (long transcriptions) to run in the background with a notification when they finish.

---

## 5. Surfaces (how users reach it)

| Surface | What it does |
|---|---|
| **Chat** | Multimodal chat (text + photo + audio + file), skill chips, thinking toggle, saved threads |
| **Voice mode** | Hands-free: on-device speech in → agent → on-device TTS out |
| **Live camera** | Point-and-ask, live description, live translate |
| **Share sheet** | "Share to PhoneDots" from any app. Audio → minutes, image → ask, text → summarize/redact |
| **Recipes** | Visual builder for skill chains (like Shortcuts), one-tap run, home-screen shortcut |
| **Automations** | Triggers: new recording, new screenshot, new download, time of day, charging + idle (good for overnight photo indexing) |
| **Widgets** | Quick voice note, last meeting summary, ask-anything |
| **OS assistants** | iOS App Intents / Siri / Shortcuts; Android App Actions / intents |
| **Model hub** | Browse, download, delete and update models; size/RAM/speed badges; per-device recommendations |
| **Skill store** | Built-in + community skills, install from URL, permission review |
| **Lab** | Prompt Lab, benchmark (tok/s, TTFT, RAM, per-skill latency), model A/B compare |
| **Privacy center** | "Nothing left this phone" ledger, memory editor, index wipe, per-skill permissions |

---

## 6. Flagship experiences (what we demo)

1. **"Minutes"**: record a meeting with the phone in airplane mode. Get a speaker-labelled transcript, summary, decisions and action items, and drop the action items into Reminders in one tap.
2. **"Ask my phone"**: "What did the landlord say about the deposit?" searches messages you shared, PDFs and voice notes, and answers with citations.
3. **"Photo brain"**: "Find the receipt from the Italian place and add it to expenses". This uses photo embeddings, vision OCR and Schemer, and finishes with a table card.
4. **"See for me"**: live camera description and reading for low-vision users, fully offline.
5. **"Make a short"**: pick a video and get the 30 s highlight with captions, a title and hashtags.
6. **"Do it"**: phone actions by voice in under 300 ms with FunctionGemma: "Silence my phone until my 3pm ends and remind me to call Sam after."

---

## 7. Tech stack

- **App:** Flutter (UI, state, navigation), with platform channels into native engines.
- **iOS native layer (Swift):** LiteRT-LM Swift API, Desert Ant `desert-ant-core` (Core ML), App Intents, EventKit, Contacts, Photos, Speech/TTS.
- **Android native layer (Kotlin):** LiteRT-LM Kotlin API (GPU, CPU fallback; constrained tool calling), Desert Ant Android SDK, Android intents, Calendar/Contacts providers, share-sheet intake.
- **Storage:** JSON documents in app support storage (threads, recipes, memory, ledger) plus an on-device vector index for EmbeddingGemma vectors (hybrid cosine + keyword).
- **Models:** hosted on Hugging Face (litert-community) and Desert Ant CDN, verified by checksum, resumable downloads, Wi-Fi-only option.

### Repo layout
```
lib/
  agent/          Agent loop, prompts, tool-call parser, conversations
  core/           Engines (interfaces, platform channels, demo), models, storage, settings, ledger, utils
  skills/         Skill model, registry, built-in skills, recipes, community skills
  knowledge/      Knowledge base (vector search) and memory
  features/       Screens: chat, voice, skills, models, lab, memory/files, privacy, settings, shell
  theme/ widgets/ Design system
android/app/src/main/kotlin/ai/phonedots/phonedots/   LlmBridge, SpecialistBridge, DeviceBridge, AudioFiles, MainActivity
ios/Runner/       LlmBridge, SpecialistBridge, DeviceBridge (Swift)
docs/             Spec, native bridge contract, iOS setup, community skill schema
test/             Unit, agent end-to-end and widget tests
```

---

## 8. Delivery plan

| Milestone | Scope |
|---|---|
| **M0 Foundation** | Flutter shell, runtime interfaces, model hub + downloads, Gemma 4 E2B chat with streaming, benchmark |
| **M1 Agent + skills** | Skill manifest/registry, tool loop, constrained calls, trace view, 15 device skills, FunctionGemma router |
| **M2 Audio** | Voz/Who/Align/Uhm/Clear skills, Minutes flow, share-sheet audio, background jobs |
| **M3 Vision** | Ask Image, Eye/Face/Moderator, receipt → expense, live camera describe |
| **M4 Knowledge** | EmbeddingGemma index for files + photos, personal memory, offline Wikipedia pack |
| **M5 Recipes & automations** | Recipe builder, triggers, widgets, Siri/App Actions |
| **M6 Community** | Skill store, install-from-URL, sandboxed JS skills, permission review |

---

## 9. Honest constraints

- **Desert Ant on Android** covers 11 of the 15 shipping models. Uhm, Align, Title and Clips are iOS-only, so Android uses Gemma for titles and skips filler-word detection.
- **RAM.** E4B needs a high-end phone. The governor must downgrade gracefully. We never load E4B and large Desert Ant models at once on devices with ≤8 GB.
- **First-load cost.** Core ML specialisation takes about 20 s the first time. We pre-warm during onboarding.
- **iOS sandbox.** Some "phone actions" (system toggles) aren't possible on iOS. Those go through Shortcuts/App Intents or aren't offered.
- **Licences.** Gemma terms, Desert Ant free up to 100k MAD, and the CC BY attribution required for Voz (Parakeet) weights all go on an in-app licences screen.
