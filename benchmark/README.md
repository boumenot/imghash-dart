# Luminance benchmark

Run from the repository root with Dart 3.3 or later:

```sh
dart run benchmark/prepare.dart
dart run .dart_tool/luminance_benchmark/luminance.dart --verify
RUNTIME=JIT dart run .dart_tool/luminance_benchmark/luminance.dart > jit.csv
dart compile exe .dart_tool/luminance_benchmark/luminance.dart -o .dart_tool/luminance_benchmark/aot
.dart_tool/luminance_benchmark/aot --verify
RUNTIME=AOT .dart_tool/luminance_benchmark/aot > aot.csv
```

`prepare.dart` generates the driver and private comparison copies of the PDQ
library under `.dart_tool/luminance_benchmark/`. The baseline reconstructs the
original luminance loop; the LUT, store, and SIMD copies substitute their
respective loops. The `hoisted` variant uses the actual production luminance
kernel and `Pdq.calculate`. Regenerate after changing production code,
benchmark kernels, or the driver template.

The five variants are the original float32 arithmetic, per-channel float32 LUTs,
LUTs with the final rounding performed by the output store, the latter with
branch/index hoisting, and four-pixel `Float32x4` arithmetic including byte
gathers. All retain the intermediate rounding between the two additions.
The LUTs occupy 3 KiB per isolate, excluding object overhead.

Verification compares every float32 output bit, including the actual production
kernel, for all 16,777,216 RGB triples, all reference fixture inputs, and 300
seeded randomized grayscale/RGB/RGBA images with padding, odd widths, and
nonzero buffer-view offsets. Each variant also checks hash and quality for the
reference fixtures and randomized images.

Measurements use seeded random packed RGB/RGBA input at 64x64, 512x512,
1920x1080, and 4000x3000. Isolated conversion reuses its output allocation;
`calculate` includes all normal allocations and consumes both hash and quality.
Input generation, verification, initialization, and compilation are not timed.
Each case/variant warms up for at least 500 ms, then collects 11 samples with
adaptive batches targeting 100 ms (at least one full invocation). Variants are
shuffled and interleaved within each case. CSV includes median, p10, p90, min,
and max milliseconds per invocation.

Override `WARMUP_MS`, `SAMPLE_MS`, or `SAMPLES` to adjust the run. Execute runtime
benchmarks sequentially, not concurrently. These are native VM measurements:
the `dart:io` driver does not itself measure Android Flutter performance.

Use `VARIANTS=baseline,hoisted` for a focused confirmation in a fresh process.
See [RESULTS.md](RESULTS.md) for the recorded evaluation and its limitations.
