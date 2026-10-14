# Redundancy review

Reviewed the tracked first-party build/setup/CI entry points and scanned Python
function bodies and native source for repeated implementations and imports.
Targeted review covered rendering submission/readback, audio recovery, haptics,
app lifecycle/shutdown, launcher imports, executable loading, translation reuse,
settings generation and packaging. Vendored code, private game inputs and
translations were excluded. This is a static review with focused tests, not a
claim that every path has been exercised on an iPhone.

## Consolidated

| Area | Finding | Change |
|---|---|---|
| Integrity | Launcher and loader maintained separate SHA-256 implementations. | Both use `kit/platform/sha256.h`; file streaming and in-memory validation keep their existing interfaces. Known digest and chunk-boundary tests cover the shared code. |
| Audio | Completed recovery threads remained stored until shutdown. | Reap completed asynchronous workers when starting another recovery, while preserving independent running jobs, cancellation and shutdown waits. |
| iOS entry points | CI wrapper passed `Release` as a signing team; local wrapper rejected unsigned option-based calls. | Both delegate to `tools/build.py` through one option parser, preserving positional team IDs and CI configuration compatibility. |
| Build configuration | iOS accepted Debug but forced Release at the final build call. | Preserve the Release-only guard against guest stack overflow and reject unsupported Debug requests explicitly. |
| Python setup | Python 3.13 selection conflicted with pinned NumPy; CI created a fake interpreter to bypass it. | One compatibility probe selects supported native Python for both system and venv paths; remove the CI shim. |
| Game validation | Setup repeated the executable pin and required folders from game.toml; CI copied part of that validation again. | Read identity/folders from game.toml and leave archive extraction in CI, with normalization, hash and folder validation owned by setup. |
| Migration tooling | One-shot UIKit cleanup and unsigned-build patch scripts targeted obsolete source shapes. | Remove those scripts and their source-mutating cleanup workflow. Continuous Core Haptics and unsigned builds are implemented directly. |
| Metal state | Stored last-frame dimensions, an in-flight boolean and a depth-match temporary had no readers. | Remove the write-only fields/temporary; keep the backbuffer identity used for HDR. |
| Native headers | Repeated unconditional imports and an identical x86.h include in both preprocessor branches. | Remove duplicate imports and the ineffective conditional. |

## Preserved deliberately

- iOS lifecycle event watching: SDL app events can be delivered only to watchers;
  an event-loop-only implementation would miss suspension. Background and
  termination safety calls are idempotent protection, not competing owners.
- Rumble sequence, player generation and engine epoch guards cover different
  lifetimes. Replacing them with a single flag would lose stale-callback checks.
- Presenter and SDL audio recovery owners stop at different teardown boundaries.
  Sharing one global task owner would couple their lifetimes.
- Metal, Vulkan and WebGPU implement the same guest operations with different
  resource/storage and synchronization rules. Matching code does not establish
  interchangeable GPU behavior.
- Launcher and loader validate at different trust boundaries. Only the hash
  implementation is shared; neither validation is removed.
- Analysis and translation caches serve different stages. Before/after input
  hashes detect inputs changing during generation; output hashes detect damaged
  reused files. Those checks are not redundant timestamp checks.
- Setup packaging and generic kit packaging have different products and inputs.
  Game-specific effects, profile defaults and signing are not folded into the
  generic desktop packager.
- Tests repeat expected identities/settings intentionally so a changed default
  or pin cannot silently validate itself.

## Remaining opportunities

- Setup rebuilds generated effect extras on every preparation. Cache those only
  after measuring their cost and defining complete dependency keys for game
  assets, effect sources, generator options and optional packs.
- Backend draw encoding and bootstrap/fixture teardown have structurally similar
  sections. A shared abstraction needs behavioral coverage before replacing
  those platform or execution-specific sequences.
- Device profiling is still needed to assess staging pressure, frame-copy
  savings, shader warm-up and whether further GPU waits can be removed safely.

The manual iOS game-data installation workflow is retained. This review does not
expand the IPA to include asset folders or remove the bundled speed.exe.
