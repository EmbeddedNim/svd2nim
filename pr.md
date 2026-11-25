# PR: Refactor `src/codegen` (Phases 1–4)

## Summary
Refactor the monolithic 966-line `src/codegen.nim` into a small set of focused modules, replace hidden global state with an explicit `CodeGenContext`, and make rendering target a stream. Generated output remains byte-identical to the master baseline (verified by golden-master checks).

## Why
- `codegen.nim` mixed data model, type-map construction, IR generation, and text rendering in one file.
- Register prefix/append options lived in a module global (`cgOpts`), making the code harder to test and reuse.
- Several latent bugs existed (enum-prefix bounds check, dim-array address suffix inconsistency, repeated distinct-type overwrite).
- Rendering was hard-wired to `File`, preventing in-memory testing.

## Changes

### Phase 1 — Bug fixes and consistency
- Fixed `getEnumPrefix` bounds check (length before indexing).
- Exported `CodeGenDistinctDef` fields for consistency.
- Guarded `createBitfieldTypes` against overwriting the same distinct type.
- Reconciled dim-array register address suffix to match existing generated output.
- Added `scripts/check_golden.nim` golden-master regression checker (`--update`, optional refspec).
- Added `golden/` to `.gitignore`.

### Phase 2 — Context object replaces global state
- Introduced `CodeGenContext` (options, symbols, type map, device, output stream).
- Removed `cgOpts` global and `setOptions`; thread context through generation and rendering.
- Flattened the former `CodeGenOptions` into `CodeGenContext`.
- Made context the first parameter of ctx-using procs/funcs; converted side-effect-free generators to `func`.

### Phase 3 — Module split
- Split into `src/codegen/{model,typemap,generate,render,internal,public}.nim`.
- `model.nim`: IR types + `CodeGenContext` + `initCodeGenContext`.
- `typemap.nim`: type-name assignment and value-type helpers.
- `generate.nim`: type/enum/accessor IR generation.
- `render.nim`: text rendering and `renderDevice` orchestration.
- `internal.nim`: facade exporting internals for tests.
- `public.nim`: public facade exporting only `renderDevice`.
- Trimmed helper visibility to only cross-module needs.

### Phase 4 — Stream-based rendering
- Added `output: Stream` to `CodeGenContext`.
- `renderDevice` creates a `FileStream` and assigns `ctx.output`; helpers write via `ctx.output`.
- Unified helper naming (`tg` → `outf`) and removed redundant stream parameters from context-aware helpers.
- Enables `StringStream`/stdout targets for testing.

## Verification
- `nimble build` passes.
- `nimble test` passes.
- `scripts/check_golden.nim` passes for all SVDs.
- Generated output remains byte-identical to golden masters.
