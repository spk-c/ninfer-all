# RTX 4090: Huihui IQ3S Vision DFlash2 qualification

## Status

Work in progress, 2026-10-29. No performance candidate is qualified or enabled.
No throughput improvement or memory reduction has been established.

Branch: `perf/rtx4090-iq3s-dflash2`, based on fork PR #7,
`572d6859670a1d9f30a1c2e9b87ad26d7f9d43c3`. The local master initially
pointed to upstream `33163f05`; only the work branch was advanced to
`origin/master`. Both remotes were fetched. PR #7 includes that upstream
revision and retains the opt-in fork experiments and regression coverage.
No commit or change to master is part of this work.

## Artifact and host

The only inference artifact selected is the existing, read-only
`C:/ninfer-all/models/Huihui-Qwen3.8-27B-GSQ-RCO-IQ3S-Vision-DFlash2.ninfer`:
15,017,456,896 bytes, artifact ID `59ac51f9c2774978b3688f36043c56f8`.
No weights were downloaded, converted or edited. Directory inspection uses
the existing Python 3.11 artifact reader, not model inference.

Text is `Qwen3_5ForCausalLM`, H=5120, 64 layers, intermediate=17408,
24 query heads, 4 KV heads, head dimension 256. Its declared position limit
is 262144. DFlash2 contains five local-attention layers, window 2048,
32 query heads, 8 KV heads, head dimension 128. Its runtime draft width is
not a stored weight dimension; counts 3, 5 and 7 are supported by the
configuration contract. Actual memory feasibility remains to be measured.
Vision and MTP are present; MTP is outside this campaign.

Unique physical objects reachable through each component's bindings, resolving
both direct and multipart bindings (object counts are not execution counts):

| Text format | Objects | Stored bytes |
|---|---:|---:|
| IQ3_S | 131 | 3642777600 |
| IQ4_XS | 89 | 3022028800 |
| IQ3_XXS | 68 | 2075279360 |
| Q4_K | 40 | 1582202880 |
| IQ2_S | 17 | 800215040 |
| Q2_K | 19 | 240844800 |
| IQ2_XS | 9 | 221265920 |
| IQ2_XXS | 6 | 98672640 |
| BF16 | 353 | 52467712 |
| IQ1_M | 1 | 19496960 |
| FP32 | 96 | 18432 |

DFlash2 binds 21 Q8 tensors (1,838,284,800 bytes) and 45 BF16 tensors
(388,508,160 bytes). Vision uses Q4/Q5/Q6/Q8 and BF16. These numbers
include physical parents once per component; they do not predict GPU time.

Host: RTX 4090, 24,564 MiB reported, WDDM with active desktop; driver 617.42,
CUDA 13.4.92, MSVC 19.44.35229, Python 3.11.9. Initial observation:
51 C, 450 W power limit, 2107 MiB total VRAM occupied. This is an idle
snapshot, not measured inference telemetry.

## Prior evidence and experiment exclusions

The complete existing [4090 workflow](../rtx4090.md),
[GGUF campaign](rtx4090-gguf-2026-10.md),
[diagnosis](rtx4090-diagnosis-2026-10.md), and
[stability investigation](rtx4090-stability-2026-10.md) govern the starting point.
Their measurements used another named artifact and are not new measurements of
this artifact. In particular, 92%/78.3% GGUF kernel shares and 128-register
T6 occupancy are historical evidence, pending current-artifact remeasurement.

Do not repeat the rejected one-row-per-warp, activation-streaming or rolled-T6
strategies without new evidence. SFU, BF16x8 SiLU and T6-loop remain OFF.
Quantized-KV plain/verification token drift is already documented; compare
candidate to baseline within the same mode and use the existing oracles.

## Baseline preparation and checks

The baseline is a fresh Release build in `build-rtx4090-huihui-base`, CUDA
architecture 89 only, tests and benchmarks enabled. Existing experiment build
directories are not accepted as baseline: their caches included rejected
ROW1/STREAM_A flags or archived experimental binaries.

The first standard-wrapper configure started rebuilding locally available
vcpkg dependencies, including FFmpeg. It was stopped before NInfer compilation.
The replacement configure reuses `build-rtx4090/vcpkg_installed`, with manifest
installation disabled, and explicitly selects Python 3.11. Initial manual
configure attempts lacked the early toolchain initialization and failed to find
FFmpeg; a fresh CMake configure with the vcpkg toolchain corrected that.
Compiler warnings from existing xgrammar sources were observed.
The initial unbounded NInfer build reduced available host RAM from about 40 GB
to 17 GB. It was stopped and resumed with `cmake --build
build-rtx4090-huihui-base -j8`; completed objects were retained. There was no
observed out-of-memory failure. Existing Attention template warnings also appear.
The first full build exposed a pre-existing link failure in
`ninfer-multi-gpu-probe`: its direct compilation of `device.cu` omitted
`peer_preflight.cpp`, producing unresolved `read_peer_device_facts` and
`peer_preflight_refusal` symbols. `tools/CMakeLists.txt` now includes that source
in the standalone probe, consistent with core's existing source list. This is
a build prerequisite fix, not a performance candidate or arithmetic change.

The unchanged baseline Python checks passed: 56 tests across
`test_bench_matrix`, `test_tune_rtx4090`, `test_speed_of_light`,
`test_gguf_bench_reader`, `test_target_trace`, and `test_engine_phases`.
The native Release build completed successfully after the standalone probe fix;
CLI and server `--help` execute. The CLI is 748526080 bytes, server 750589440
bytes and calibration executable 708041728 bytes. Binary SHA-256 records are
retained in `baseline-hashes.json`. Comparative performance qualification is pending.

The initial broad 362-test CTest attempt exposed a pre-existing Windows failure
in `ninfer_multi_gpu_test`: its Linux sysfs fixture creates PCI directory names
containing colons, which Windows rejects. The next expert-delivery test did not
complete within 180 seconds and was stopped, together with the broad run. It is
not a passing result or an established diagnosis of that asynchronous delivery
problem. That dense-model-unrelated investigation is outside this optimization.
The initial partial log and explicit stop reason are retained. A selected
215-test run covering all registered Op tests plus Graph, speculation and
protocol/report checks completed serially: 213 passed, 2 skipped, no failures,
3204.20 seconds. Skips: the real-artifact n-gram graph planning prerequisite and
the hardware-specific NVFP4 TMA staging race test. A 600-second default per-test
timeout was used (individual registered timeout properties still apply).
No test or numerical tolerance has been changed or disabled in source.

The original `ninfer_bench` had no FP16 GDN-state option and used the Engine's
FP32 default. The measurement interface now accepts `--gdn-state-fp16`, forwards
it to the existing Engine option, and reports the actual selected option in
table/JSON/CSV. The benchmark's default remains FP32. CLI/default and JSON
contract checks were added; the rebuilt benchmark and contract test pass. This changes
neither CUDA arithmetic nor Engine defaults. New performance comparisons will
use this same measurement-only change in both arms.

Local build logs, artifact directory inspection and component inventory are
under `profiles/bench/huihui-4090/`. No old binary's timing is substituted for
the new baseline.

The tiled default benchmark corpus is unsuitable as sole evidence of daily-use
speculative acceptance. A task-local 180000-token corpus was prepared from 23
ordered tracked repository documents/code files without tiling, using the
artifact's own tokenizer resource. It has 10250 distinct token IDs. The
`tokenizers` package was installed only into the ignored task output directory;
global Python packages and the model were not changed. The source manifest and
IDs are retained there. Real chat/code prompts are still required for the
serving recommendation. Exact matrix output counts require `-pg P,127` or
`-pg P,255`: the benchmark's G counts decode intervals after the first output.

## Current-artifact functional and profiling evidence

The rebuilt benchmark contract passes. The artifact starts with context/KV
capacity 176128, rk4v4, FP16 GDN state, chunk1024 and CUDA Graphs. With DFlash2-5,
the Engine reports 14360105472 weight bytes and 4179599872 runtime-reservation
bytes, including 3156213760 KV-payload bytes. These are Engine reservations,
not sampled total-board VRAM. The first complete plain matrix reaches 100000
prompt tokens and produces all 128 requested outputs without failure. Its
sampled PID peak is 14968.26 MiB; board peak 16969 MiB including the desktop.
This single process is not a distribution or an optimization result.

The existing real DFlash2 test passes with this exact artifact:
`ninfer_tests ninfer_qwen3_5_dflash2_real_test 5 1 1 1 int8 1 1`, with
`NINFER_TEST_ARTIFACT` set to the absolute model path above. It exercises Graph
acceptance/rollback, retained-prefix restore and its synthetic image/video
Vision fixtures. It reports 18/20 accepted drafts on its first request.
That integration test uses INT8 KV and the test's default FP32 GDN state;
it does not replace the requested rk4v4/FP16 performance/greedy comparisons.

Systems2026.3.2 node traces capture one measured pp2048+tg255 request after
warmup, with the custom non-tiled corpus, max context176128, rk4v4, FP16 state,
chunk1024 and Graphs. DFlash2 uses five drafts and n-gram drafts0. The existing
phase analyzer supplies decode intervals; kernel durations are clipped at every
interval boundary. An initial containment-only aggregation omitted boundary
overlaps; correcting it changes DFlash2's provisional 78.67%/26.52% figures to
78.09%/26.33%. The corrected numbers below are authoritative.

| Decode capture | GGUF vector share of summed kernel time | IQ3_S share |
|---|---:|---:|
| Plain | 91.90% | 30.22% |
| DFlash2-5 | 78.09% | 26.33% |

Host decode phase wall time outside traced CUDA activity totals about260 ms
plain and70 ms DFlash2 in these captures. These are elapsed intervals, not a
CPU-busy or WDDM-causality measurement. CPU scheduling/WDDM coverage and aligned
profile telemetry are incomplete. Profiled throughput is not pooled with any
unprofiled result.

Compute2026.3.1 full kernel-replay captures, first measured unfused IQ3_S/K5120
product (the 10240-row projection, 22528000 stored bytes):

| Metric | T1 | T6 |
|---|---:|---:|
| Duration us | 28.448 | 31.680 |
| DRAM read bytes | 22898304 | 23337984 |
| DRAM read GB/s | 804.92 | 736.68 |
| Registers/thread | 56 | 128 |
| Achieved occupancy | 65.95% | 30.05% |
| Global-load L1 sectors (32 bytes each) | 5500928 | 14163968 |
| L2 sectors | 915923 | 1069679 |
| Spilling requests | 0 | 0 |

Both captures use45 replay passes and warn about system-memory backup. They
support a near-one-pass DRAM stream and substantial cache traffic, not natural
cache residency for every layer or an Engine speedup. Current DRAM traffic
does not support a hypothesis of sixfold weight rereads.

The old diagnostic target-trace patch fails `git apply --check` (malformed blank
context); a task-local normalized/recount attempt also fails current-source
context matching. Neither was applied. Fresh raw-logit tracing is not yet
available from that patch. Native exact argmax, acceptance and independent
numerical checks above pass; the patch failure is not an inference failure.

## Isolated candidate, not qualified

`NINFER_ADA_GGUF_IQ3S_WARP_META` is OFF by default and restricted to a single
SM89 build. Only unfused IQ3_S/K5120/T1 or T6 dense products use the alternate
decoder. Eight adjacent lanes share the block's half scale and four scale bytes
through two shuffles. No stored weights, q8_1 quantization, integer dots,
accumulation order, output conversion, launch topology or workspace change.
This targets redundant logical metadata requests, not DRAM weight rereads.
Additional shuffle/predicate and register costs are explicitly unqualified.
Compilation and candidate GPU testing wait for the unprofiled B/B campaign.

The existing greedy-comparison controller now optionally forwards
`--gdn-state-fp16` to both CLI arms, so the quality comparison can use the same
state representation as the requested performance setup. Python3.11 compilation
passes. All six baseline/candidate comparisons pass: 68-token CUDA/German and
3585-token long prompts, 64 generated IDs plus exact UTF-8 text, plain and
DFlash2-5, rk4v4, FP16 state and Graphs. Cross-backend identity is not promised:
the German prompt first differs at token32, identically in both arms.

The candidate build passes GGUF Linear (including the IQ3_S FP64 oracle), CPU
GGUF and benchmark contract tests (27.81 seconds). Its real-artifact Graph,
prefix and Vision integration test also passes with the same arguments and
18/20 initial accepted drafts as baseline.

Single-kernel full-replay observations, same filter/method as baseline above:

| IQ3_S/K5120 unfused | Baseline T1 | Metadata T1 | Baseline T6 | Metadata T6 |
|---|---:|---:|---:|---:|
| Duration us | 28.448 | 27.200 | 31.680 | 29.280 |
| Registers/thread | 56 | 64 | 128 | 128 |
| Achieved occupancy % | 65.95 | 58.19 | 30.05 | 31.27 |
| DRAM read bytes | 22898304 | 22672256 | 23337984 | 22649344 |
| L1 global-load sectors | 5500928 | 5684736 | 14163968 | 14355968 |
| Spilling requests | 0 | 0 | 0 | 0 |

The T1 register/occupancy regression and increased L1 sectors are real costs.
Faster isolated captures do not prove reproducibility or an Engine improvement;
cache/replay and clock differences are not eliminated. No gain is adopted.
Six alternating A/B pairs over all five prompt lengths and both modes are now
running, unprofiled, with identical fixed corpus/configuration and the staged
baseline/candidate binaries. No concurrent compilation or other task GPU work.

## Completed baseline variance series

Three identical-binary B/B pairs per mode, AB/BA order, one discarded warmup
and one measured repetition per case/process, all five requested prompt/output
counts, max context176128, rk4v4, FP16 state, chunk1024, Graphs, concurrency1.
Clocks are unlocked, existing power limit450 W. Memory clock remains10501 MHz
in the inspected busy samples; core clocks and temperature vary. This is a
daily-use WDDM/desktop condition, not a fixed-clock experiment. Raw telemetry
includes startup, warmups and idle periods; sampled peaks are not instantaneous
allocator maxima. Each process records the exact executable SHA-256.

Paired Decode B/A changes, percent; favorable and adverse observations retained:

| Prompt/output | Plain median [min,max] | DFlash2-5 median [min,max] |
|---|---:|---:|
| 512/128 | +0.09 [-8.63,+0.62] | +0.04 [-13.03,+3.89] |
| 2048/256 | -0.46 [-1.30,+0.05] | -0.23 [-1.45,+0.70] |
| 8192/256 | +0.13 [+0.07,+2.62] | +0.56 [-5.75,+4.82] |
| 32768/256 | +0.04 [-0.08,+1.41] | +0.07 [-0.87,+10.85] |
| 100000/128 | +0.33 [-0.46,+0.66] | -1.37 [-2.46,+0.11] |

Every same-case DFlash2 B/B run has matching round/draft/accept counts. The
short-case outliers and 32K positive excursion are therefore not explained by
a changed speculative work count. No causal diagnosis is claimed. Plain
prefill's first pair spans -9.57% to+8.86%; the raw reports retain TTFT too.
Complete paired summaries and every individual sample are under
`profiles/bench/huihui-4090/bb-full/{summary.json,samples.csv}`.

The 2K DFlash2 Systems capture also separates GPU kernels by the native
prepare-verify and speculative-sampling boundaries: 16.98 ms/round target
forward/argmax, 3.015 ms draft plus context materialization, 0.145 ms GPU
transition/acceptance. The Engine's complete profiled decode round averages
21.08 ms. There are73 rounds,364 drafted and182 accepted tokens: 2.493 accepted
drafts/round,3.493 outputs/round including the verified token. Component GPU
rates are352.58 valid target columns/s and1654.04 draft tokens/s including
context materialization. These denominators differ from output throughput and
are not pooled with unprofiled measurements. Boundary/host elapsed time is not
CPU-busy time. Target arithmetic remains the dominant measured component.

## Outstanding acceptance work

Baseline variance, candidate compilation/qualification, six alternating pairs,
draft3/5/7 comparison, complete repeated prompt matrix and rk4v4/FP16 greedy
comparisons, serving prefix reuse and live server/tool-calling remain outstanding.
No recommended optimized launch configuration can yet be justified.
