# Community skills

A community skill is a small JSON file served over **https** (64 KB at most). It contains no code. It can do one of two things:

- **Prompt skill:** fill a template and run it on Gemma.
- **Chain skill:** call existing skills in order. Each skill in the chain keeps its own permission prompt, so installing a chain can never grant more than the user already allows.

Install one from **Skills → Community → paste URL → Add**. The app shows the name, author, description and any skills it calls before installing.

## Schema `phonedots.skill/v1`

```json
{
  "schema": "phonedots.skill/v1",
  "id": "packing_list",
  "name": "Packing list",
  "author": "You",
  "version": "1.0",
  "description": "Build a packing checklist for a trip.",
  "params": [
    {"name": "trip", "type": "string", "description": "Destination, length and activities."}
  ],
  "prompt": {
    "system": "Write a packing list, one item per line, no headings, at most 25 items.",
    "user": "Trip: {{trip}}"
  },
  "output": "checklist",
  "examples": ["Pack for 3 days of hiking in Norway"]
}
```

| Field | Rules |
|---|---|
| `id` | lower_snake_case, 3–41 characters. Installed as tool `c_<id>`. |
| `params[].type` | `string`, `number`, `integer`, `boolean`, `list`, `image`, `audio` |
| `prompt.system` and `prompt.user` | `{{param}}` placeholders. Image params are passed to Gemma vision. |
| `output` | `text` (default), `json` (key/value card), `checklist` (one item per line) |
| `steps` | Instead of `prompt`: `[{"skill": "redact_pii", "args": {"text": "{{text}}"}}, …]`. Inside step args, `{{prev.field}}` and `{{steps.N.field}}` refer to earlier results. |

Exactly one of `prompt` or `steps` must be present.

## Chain example

```json
{
  "schema": "phonedots.skill/v1",
  "id": "safe_summary",
  "name": "Safe summary",
  "description": "Summarize text, then strip personal details so it is safe to share.",
  "params": [{"name": "text", "type": "string", "description": "Text to summarize."}],
  "steps": [
    {"skill": "summarize", "args": {"text": "{{text}}"}},
    {"skill": "redact_pii", "args": {"text": "{{prev.result}}"}}
  ]
}
```
