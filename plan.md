# Refactor plan for `src/codegen.nim`

## Goal
Split the 966-line `src/codegen.nim` into focused, testable modules, remove global state, and separate IR generation from text rendering, without changing generated output.

## Non-goals
- No change to generated `.nim` output (golden files must stay byte-identical).
- No change to SVD parsing or transformations.

## Target layout

```
src/
  codegen/
    model.nim        # CodeGen* types, constructors, CodeGenOptions, CodeGenContext
    generate.nim     # buildTypeMap, createTypeDefs, enums, distinct, accessors
    render.nim       # all render* (return string) + file writing orchestration
  codegen.nim        # aggregator: import all submodules, re-export public API
```

## Phase 1 — Bug fixes + consistency (low risk, no structural change)
Files: `src/codegen.nim`

1. Fix `getEnumPrefix` index-before-length: reorder condition to `lastPart.len > 0 and lastPart[0] notin Letters`.
2. Reconcile register address suffix: make dim-array branch emit `'u` like single branch (or remove both); decide based on golden diff.
3. Export `CodeGenDistinctDef` fields (`name*`, `public*`, `baseType*`).
4. Guard `createBitfieldTypes` overwrite: only set `result[fieldTypeName]` when not present.
5. Memoize enum creation in `getFieldDefaultVal` (reuse `createFieldEnums` result or cache by `(field name, regType)`).

Exit criteria: existing tests pass; golden output unchanged (diff generated files before/after).

## Phase 2 — Context object replaces global state
Files: `src/codegen/model.nim` (new), `src/codegen.nim`

1. Define:
   ```nim
   type CodeGenContext* = ref object
     opts*: CodeGenOptions
     symbols*: HashSet[string]
   ```
2. Replace `var cgOpts` with `ctx.opts`; thread `ctx` through. Mutability rule: only procs that mutate `ctx.symbols` (or opts) take `var ctx`; read-only ones take `ctx` by value:
   - `getRegisterPrefixSuffix(p, ctx)` — pure func
   - `getObjectMemberName(dev, n, ctx)` — pure func
   - `buildTypeMap(dev, ctx)` — pure func (opts only)
   - `createTypeDefs`, `createFieldEnums`, `createBitfieldTypes`, `createAccessors`, `createBitfieldAccessors` — pure funcs returning IR; `ctx` by value
   - `renderDeviceConsts(dev, var ctx, ...)` — mutates symbols → `var ctx`
   - `renderPeripheralRegTypeDefs/Instances/Accessors(dev, var ctx, typeMap, ...)` — mutate symbols → `var ctx`
3. No backwards-compat shim: update `src/svd2nim.nim`, tests, and any callers to the new context-based API as part of the refactor.
4. Move `CodeGen*` types and `CodeGenOptions` into `model.nim`; `codegen.nim` re-exports.

Exit criteria: tests updated to construct `CodeGenContext`; output unchanged.

## Phase 3 — Module split
Files: `src/codegen/model.nim`, `src/codegen/generate.nim`, `src/codegen/render.nim`.

Move functions preserving signatures (now with `ctx`):
- `model.nim`: types, constructors, `nimIdentKey`? keep in codegen root or utils; recommend `utils.nim`.
- `generate.nim`: `buildTypeName` (both overloads), `buildTypeMap`, `hasOwnType`, `createTypeDefs`, `getObjectMembers`, `createRegisterType`, `createEnum`, `getEnumTypeName`, `getEnumPrefix`, `createFieldEnums`, `createBitfieldTypes`, `getRegValueType`, `getFieldType`, `hasFields`, `hasSingletonField`, `createBitfieldAccessors`, `createAccessors`, `createFieldsWriter`, `getFieldDefaultVal`.
- `render.nim`: all `render*` + `asSingleLine`, `quoted`, `convertCpuRevision`, plus `renderDevice` orchestration and file writes.

`codegen.nim` becomes:
```nim
import codegen/model, codegen/typemap, codegen/types, codegen/accessors, codegen/render, codegen/io
export model, typemap, types, accessors, render, io
```

Exit criteria: `nimble test` passes; import paths in `svd2nim.nim` and tests unchanged.

## Phase 4 — Separate generation from I/O
Files: `src/codegen/render.nim`, `src/codegen/model.nim`

1. Signature style: every `render*` proc takes `ctx` as first arg (OOP/UFCS-friendly: `ctx.renderX(...)`). Mutating ones (`renderDeviceConsts`, `renderPeripheralReg*`) take `var ctx`; read-only ones take `ctx` by value.
2. `render*` return `string` instead of writing to `File`. Pure generation; no hidden I/O.
3. Add optional output support to context without baking I/O into generators:
   ```nim
   type CodeGenContext* = ref object
     opts*: CodeGenOptions
     symbols*: HashSet[string]
     output*: Option[ref (proc(s: string))]  # optional writer
   proc write*(ctx: CodeGenContext, s: string) = if ctx.output.isSome: ctx.output.get()(s)
   ```
   Generators may call `ctx.write(...)` for streaming, but default path uses returned strings.
4. `render.nim` (`renderDevice`) owns all file writes: compose returned strings, write to disk; configure `ctx.output` only if streaming is desired.
5. `renderCoreModule`/`renderUncheckedenums` return content; caller writes file.

Exit criteria: output byte-identical; unit tests can assert on returned strings; no generator opens files.

## Phase 5 — Algorithm cleanup
Files: `src/codegen/generate.nim`

1. Replace manual stack in `createTypeDefs` with recursive helper `addTypeDefs(regNode, ...)`; preserve ordering (tests check member order).
2. Extract `sortedMembers(parent)` helper used by `getObjectMembers` and `renderObjectMembers`.
3. Single pass in `renderPeripheralRegAccessors`: iterate peripherals once, collect into context, render at end.
4. Remove duplicate `cmpAddrOffset` sort duplication.

Exit criteria: tests pass; generated output unchanged.

## Phase 6 — Tests & golden files
Files: `tests/test_codegen.nim`, new `tests/golden/`

1. Add golden-output test: run full generation on `tests/ARM_Example.svd`, compare to committed `tests/golden/ARM_Example.nim`.
2. Update unit tests to use `CodeGenContext` (remove `setOptions` global usage where possible).
3. Keep `ARM_Example` and `ATSAMD21G18A` integration tests.

## Verification
- `nimble test` (runs build + integration).
- Manual: `./build/svd2nim ... -o /tmp/out` before/after each phase; `diff` generated files.
- `nim check` on each new module.

## Risks
- Ordering of type definitions and members matters for tests and downstream compile; preserve DFS + reverse + `cmpAddrOffset`.
- `renderDevice` side effects (core module, uncheckedenums files) must remain in same order.
- Nim module cycles: `model` must not import higher modules; keep dependency DAG model <- generate <- render.

## Estimated effort
- Phase 1: small (hours)
- Phase 2: medium
- Phase 3: medium
- Phase 4: large (many signatures)
- Phase 5: medium
- Phase 6: medium
</content>
filePath="/home/francis/source/svd2nim/plan.md"