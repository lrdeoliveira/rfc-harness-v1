---
description: Show the status of the init spec chain (.spec/init/*) — present, absent, or stale — and run the next init:* command in the chain. Writes nothing itself; all authoring lives in the invoked init:* commands.
allowed-tools: Read, Bash, Glob, Grep, SlashCommand
---

# init

You are the router for the init spec chain. You inspect the state of the artifacts, report it, and invoke the next command in the chain. You never write or edit any artifact yourself — all authoring lives in the `init:*` commands you invoke.

## The chain

| # | Artifact | Produced by | Inputs (stamped on line 3) |
|---|---|---|---|
| 1 | `.spec/init/project-description.md` | `/init:project-description` | — (head of chain, no stamp) |
| 2 | `.spec/init/user-stories.md` | `/init:user-stories` | project-description.md |
| 3 | `.spec/init/database-schema.md` | `/init:database-schema` | project-description.md, user-stories.md |
| 4 | `.spec/init/project-phases.md` | `/init:project-phases` | project-description.md, user-stories.md, database-schema.md |
| — | `.spec/init/design/` | developer (manual) | — |

`.spec/init/design/` is always a **manual artifact**: the developer creates and populates it; no `init:*` command writes there. Its absence is never an error. `init:project-phases` reads it when present — screen and component tasks point at design refs inside it.

## Flow

### 0 — Observed stack + chain status

Prefer the harness script — it draws the same table, the freshness stamps, and the OBSERVED stack (manifests only; `.env` is never read):

```bash
_status=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/init-status.sh" ]; then
  _status="${CLAUDE_PLUGIN_ROOT}/scripts/init-status.sh"
elif [ -x scripts/init-status.sh ]; then
  _status="scripts/init-status.sh"
fi
if [ -n "$_status" ]; then
  "$_status" --plain
else
  # fallback below when the plugin scripts are not on disk
  true
fi
```

If the script ran, use its markdown as the report (steps 1–3 are already in it) and skip to **4 — Next step**. If it is missing, fall through to the inline checks.

### 1 — Presence

```bash
for f in project-description user-stories database-schema project-phases; do
  test -f ".spec/init/$f.md" && echo "present: $f.md" || echo "absent: $f.md"
done
test -d .spec/init/design && echo "present: design/" || echo "absent: design/"
```

### 2 — Freshness

Line 3 of each generated downstream artifact records the inputs it was built from (`file@sha256:<12 chars>`). Recompute and compare:

```bash
# prints nothing when the whole chain is fresh; any output = an input changed after that artifact was generated
for doc in user-stories database-schema project-phases; do
  [ -f ".spec/init/$doc.md" ] || continue
  for pair in $(sed -n '3p' ".spec/init/$doc.md" | grep -oE '[a-z0-9.-]+\.md@sha256:[0-9a-f]{12}'); do
    [ "$(sha256sum ".spec/init/${pair%%@*}" | cut -c1-12)" = "${pair##*:}" ] \
      || echo "stale: $doc.md predates current ${pair%%@*}"
  done
done
```

A present file whose line 3 carries no stamp predates the staleness mechanism — freshness unknown, report it as such.

### 3 — Report

Lead the developer-facing reply with the next command or action. One state line names the pipeline step (`init N/4 — <name>`, or `init — chain complete`). Then the required table, interview, or checkpoint. End with one action doable in under two minutes. No preamble, no recap, no closer. Errors: location, cause, fix. No drama.

This shapes the conversation with the developer. It does not apply to ralph.sh implementation sessions, agent-to-router handoffs, or generated artifacts (SPEC / PLAN / PHASES / AGENTS stay complete).

Emit one table:

| Artifact | Status |
|---|---|
| `.spec/init/project-description.md` | `present` / `absent` |
| `.spec/init/user-stories.md` | `present` / `absent` / `stale (<input> changed)` / `present (no stamp)` |
| `.spec/init/database-schema.md` | same |
| `.spec/init/project-phases.md` | same |
| `.spec/init/design/` | `present (manual)` / `absent (optional)` |

After the table, quote any `stale:` lines from step 2 verbatim.

Also emit the **OBSERVED** stack (from `init-status.sh --plain` or, if the script is missing, by inspecting manifests — never by reading `.env`). Label each stack fact `OBSERVED` (file/manifest on disk), `INFERRED` (reasonable deduction), or `UNKNOWN` (not in the repo). Do not invent a stack.

### 4 — Next step

Pick exactly one action — first rule that matches wins — and **invoke it via the SlashCommand tool** (plugin-namespaced, e.g. `/bc-harness:init:project-description`). The first line the developer sees is that command (or `Chain complete and fresh — nothing to do.`). State in one line which command you are invoking and why, then invoke it; the invoked command owns the interview and the artifact from there.

1. **An artifact is absent** → invoke the command of the first absent artifact in chain order (1 → 4). Earlier artifacts must exist before later ones make sense.
2. **An artifact is stale** → re-invoke the command of the first stale artifact in chain order. Re-runs are upsert-safe: the command interviews only about deltas and refreshes the stamp. Note that regenerating it may in turn mark artifacts downstream of it stale — re-check with `/init` afterwards.
3. **All present and fresh** → nothing to invoke; report `Chain complete and fresh — nothing to do.` If any artifact is `present (no stamp)`, add one line: its freshness can't be verified until its command is re-run once.

If the SlashCommand invocation fails (tool unavailable or command not found), fall back to recommending the command by name — never leave the developer without a next step.

## Rules

- **Writes nothing itself** — never Write or Edit; this command produces no artifact and changes no file. Authoring happens only inside the invoked `init:*` command.
- **One hop per run** — invoke at most one `init:*` command; never chain multiple in a single `/init` run. The developer re-runs `/init` to advance.
- **Never block, never nag** — staleness is a warning, not an error. The developer can always abort the invoked command's interview.
- **Thin router** — no template or interview content in this file; the `init:*` commands own all of it.
- **No git writes** — never stage, commit, or reset.
