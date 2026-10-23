<!-- Title like the commit subject: `area: imperative summary`, under 72 characters. Areas: core, overlay, storage, merge, live, docs, ci, bench. -->

## What

## Why

## How it was tested

## Deliberately left out

## Checklist

- [ ] `mix ci` passes (format, compile with warnings as errors, credo strict, tests)
- [ ] `CHANGELOG.md` has a line under `Unreleased` for every user-facing change
- [ ] Docs are updated in this PR; a change to `docs/DESIGN.md` has an ADR in `docs/adr/`
- [ ] A change to code a formal model stands for (`verification/model_map.exs`): the steps checked are named above, the model is updated if the rule changed, and `verification/model_map.stamps` is committed
- [ ] One topic only: no refactor bundled with a feature
- [ ] A new dependency has a line in this description saying why it is worth it
