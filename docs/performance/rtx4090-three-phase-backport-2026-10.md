# RTX 4090 targeted backport: stability, Qwen Code caching, GPU profiling

**Working branch:** `feature/rtx4090-upstream-stability-cache-profiling`  
**Target:** single RTX 4090 / Windows / CUDA 13.4 / Huihui Qwen3.8-27B (IQ3_S + DFlash2)  
**Policy:** No broad merge of divergent upstream histories; no changes to the released `rtx4090-v0.1.0` tag and no performance claims without measured RTX 4090 evidence.

## Phase 1 — memory stability and request lifecycle

| Candidate | Source | Status in this fork | Action |
| --- | --- | --- | --- |
| Workspace-layout exception safety | [Neroued d602894a](https://github.com/Neroued/ninfer/commit/d602894abcd071c273003f021258f46608aab447) | Already addressed by `LayoutBuilder::add` using local offset and `checked_add`; `tests/test_layout.cpp` has overflow, scope and exception-unwind regression tests | **Hardened** `LayoutRegion::bind`: reject out-of-range spans before base+offset arithmetic and detect address wraparound; added a binding regression |
| Configurable startup-memory headroom | [Neroued 6dd2b1b4](https://github.com/Neroued/ninfer/commit/6dd2b1b4e3) | Our `--kv-headroom-mib` and `--wddm-evictable-budget` exist, but are **not equivalent** to that upstream's end-to-end startup memory reservation model | **Not cherry-picked**: requires a separate multi-model memory-budget design and side-by-side VRAM/startup tests to avoid changing production allocation semantics |
| Streaming waits/admission | [Neroued 45f74287](https://github.com/Neroued/ninfer/commit/45f7428775) | Already has admission queues, `--pending-timeout-ms`, and Engine submissions before streaming generation; `src/serve/openai_chat_http.cpp` uses `GenerationService::prepare` before establishing its SSE stream | Preserve existing implementation; run live blocked-admission/cancellation/HTTP error contract tests before any transplant |
| Listener port reuse | [Neroued a062e016](https://github.com/Neroued/ninfer/commit/a062e0165e) | Already has `SO_REUSEADDR` and successor bind checks in `tests/test_http_transport.cpp` | No duplicate port |
| Terminal response ordering | [Neroued 704fa68d](https://github.com/Neroued/ninfer/commit/704fa68da9) | Branches differ in Engine and result ownership | Further full Engine/HTTP regression required before attempting this large backport |

**Phase 1 execution gate:** C++ `ninfer_test_layout` and HTTP protocol tests need compiling with the project's full C++ dependencies. The CPU-only GitHub workflow in this branch checks Python and PowerShell, **not** CUDA runtime behavior; do not mark C++/GPU tests passed on the basis of that workflow.

## Phase 2 — Qwen Code session caching and Context-Store

- [Don-Chad 931bd49b](https://github.com/Don-Chad/ninfer-3090/commit/931bd49ba3) adds a private end-of-prompt anchor for a nonempty `prompt_cache_key` in Chat Completions.
- **Already present** in this fork: `src/serve/openai_chat_request.cpp` sets `private_cache_boundary_at_prompt_end`; `src/serve/openai_common.cpp` validates keys up to `kMaximumContextCacheSessionKeyBytes`. Basic tests already existed.
- **New test coverage:** a multi-turn assistant/tool exchange, both streamed and aggregate request parsing, explicit cache mode, malformed numeric keys. The test verifies the *parser contract*; it does not claim cache hit speedup or user-session isolation by itself.
- [Don-Chad e5dac143](https://github.com/Don-Chad/ninfer-3090/commit/e5dac1437c) isolates context-store export failures per candidate in its legacy ResourceManager. This fork uses the **hybrid prefix cache by default**, with different store/resource-manager internals. Never cherry-pick the old logic wholesale. Existing GPU-backed `tests/models/qwen3_5/test_context_store.cpp` exercises store/replay and abort paths. Candidate-specific failure recovery is a separate integration test with real CUDA and memory pressure.

**Recommended Qwen Code test:** send a stable `prompt_cache_key` for repeated tool turns; compare warm TTFT, recomputed prefill tokens, cache reuse and output identity against requests without the key at the same prompt/model/context settings. Capture samples from both aggregate and SSE modes, including cancellations and overlapping requests. Do not confuse `prompt_cache_key` parsing with proof that live cache hits occurred.

## Phase 3 — CUDA Graph memory, CPU / scheduling overhead, IQ4_XS

The repository already includes:
- `tools/bench/run_graph_allowance_sweep.py`: repeated startup-graph allocation observations;
- `tools/bench/compare_graph_allowance_sweeps.py`: rejects mismatched configs and inconclusive sample ranges;
- `tools/bench/run_interleaved_ab.py`: paired, alternating throughput comparisons;
- `tools/bench/analyze_engine_phases.py`: attribution using native benchmark JSON + Nsight SQLite and explicit measured NVTX ranges.

This branch adds:
- `scripts/measure-rtx4090-regressions.ps1`: records the exact model and executable identity, runs graph-memory sweeps at **8,192 / 32,768 / 65,536** KV and **five repeats**, optionally compares baseline/candidate, and captures a **DFlash2, K=5, rk4v4, 128-token decode** with Nsight Systems `--cuda-graph-trace node`.
- `tools/bench/rtx4090_kernel_share.py`: consumes **measured** `cuda_gpu_kern_sum` CSV; reports IQ4_XS, IQ3_S, IQ3_XXS shares of **summed kernel durations**, never CPU or elapsed wall time; fails on missing or malformed data. Tests cover arithmetic and absent target kernels.
- Nsight `cuda_api_sum`: host-side **CUDA API elapsed durations** for launch/sync triage. These are **not** CPU instruction time; a long CUDA API interval alone cannot prove a Python/CPU bottleneck. Use `analyze_engine_phases.py` with compatible real trace sidecars to distinguish measured prefill/decode NVTX phases.

On the RTX 4090 PC, from the fork checkout:

```powershell
git fetch origin
git switch feature/rtx4090-upstream-stability-cache-profiling
# Build matched runtime + bench binaries with CUDA 13.4 and SM89 before running.
pwsh -NoProfile -File .\scripts\measure-rtx4090-regressions.ps1 `
  -Model "C:\path\to\your-model.ninfer" `
  -Cli ".\build-rtx4090\apps\ninfer.exe" `
  -Bench ".\build-rtx4090\bench\ninfer_bench.exe" `
  -Nsys "C:\path\to\nsys.exe" `
  -Out ".\profiles\bench\rtx4090-audit" -PlanOnly

# Remove -PlanOnly to measure. -CandidateCli can additionally compare graph
# allocation observations from another build (not a throughput comparison).
```

**Interpretation gates:** Close games, other LLM servers and competing GPU applications; record driver, clocks/power, revision, model and device profile. If CUDA Graph memory numbers cannot be parsed, fail instead of treating missing data as zero. For IQ4_XS changes, require an unprofiled interleaved A/B benchmark **and** correct/identical greedy tokens across prompt lengths (2K, 32K and longer). Traces identify bottlenecks; they do **not** themselves establish performance gains.

The previous qualified baseline records IQ4_XS at **18.49% of summed DFlash2 GPU kernel time** in its specific capture ([Huihui report](rtx4090-huihui-iq3s-dflash2.md)). That is **historical evidence**, not a new measurement from this branch.

## Validation and merge criteria

- GPU-free CI: `pytest` of graph allowance + comparison + IQ4 kernel parser, and syntax parsing of the PowerShell driver.
- Full C++ release/dev builds: layout, HTTP/Chat protocol, Qwen3.5 context-store tests and streaming admission regression tests.
- Real RTX 4090: run the campaign above, preserve unedited Nsight source traces and the manifest; use paired interleaved A/B if proposing a performance-affecting default change.
- **No automatic merge**. Review the draft PR only after missing tests and the actual GPU campaign are complete. The release tag is untouched.
