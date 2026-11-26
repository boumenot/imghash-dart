# PDQ luminance evaluation

## Adopted change

RGB and RGBA pixels use three 256-entry `Float32List` tables containing the
reference-rounded product for each possible channel value. The red-plus-green
sum is still explicitly rounded to float32; storing the final sum in the
float32 output buffer performs its final rounding. The grayscale branch and
per-pixel indexing were moved out of the color inner loop. Alpha is still
ignored. The tables consume 3 KiB per isolate, excluding object overhead.

The idea was prompted by
[Image Processing with Strings](https://ashvardanian.com/posts/image-processing-with-strings/).
That article uses SIMD byte-shuffle instructions for byte-to-byte lookup
tables. Dart does not expose those instructions directly; these are ordinary
scalar float32 lookup tables, not the article's SIMD implementation.

## Evaluation

Five implementations were measured: the original arithmetic, per-channel
lookup tables (`lut`), lookup tables with final rounding on output store
(`store`), lookup tables plus output-store rounding and branch/index hoisting
(`hoisted`), and four-pixel `Float32x4` arithmetic including byte gathers
(`simd`). All preserve the reference's float32 intermediate rounding.

The following ranges are **baseline median / variant median** across eight
RGB/RGBA size combinations from the initial sweep. Values above 1 are faster;
they are descriptive ranges, not confidence intervals.

| Variant | Luminance JIT | Luminance AOT | Full calculate JIT | Full calculate AOT |
|---|---:|---:|---:|---:|
| LUT | 1.10-1.16x | 1.06-1.14x | 1.00-1.07x | 0.98-1.10x |
| LUT + store | 1.17-1.23x | 1.10-1.24x | 1.01-1.13x | 0.98-1.08x |
| Hoisted | 1.19-1.25x | 1.20-1.25x | 0.99-1.12x | 0.98-1.14x |
| SIMD | 3.38-3.77x | 0.85-1.04x | 1.13-1.22x | 0.86-1.04x |

A fresh-process baseline-versus-hoisted sweep found isolated luminance
speedups of 1.16-1.32x on JIT and 1.17-1.38x on AOT. The full-calculation
results varied substantially between runs, with overlapping spreads. SIMD
was not adopted: its JIT gain did not translate to a consistent AOT gain.

## Integrated AOT results

After integration, the benchmark was rerun against the original loop using
the actual production kernel and `Pdq.calculate`. Each value is milliseconds
per image, shown as **median [p10, p90]** over 11 samples. These are sample
percentiles, not confidence intervals.

| Size / format | Original luminance | Production luminance | Original calculate | Production calculate |
|---|---:|---:|---:|---:|
| 64x64 RGB | 0.0322 [0.0312, 0.0361] | 0.0259 [0.0244, 0.0286] | 1.052 [0.800, 2.189] | 1.010 [0.841, 1.419] |
| 64x64 RGBA | 0.0331 [0.0313, 0.0351] | 0.0283 [0.0271, 0.0324] | 0.904 [0.814, 1.210] | 0.855 [0.829, 1.134] |
| 512x512 RGB | 2.519 [2.168, 5.313] | 2.015 [1.813, 2.839] | 16.396 [15.680, 17.247] | 16.098 [15.737, 16.725] |
| 512x512 RGBA | 2.213 [2.083, 2.362] | 1.760 [1.712, 1.810] | 15.796 [15.219, 16.137] | 15.365 [14.969, 18.766] |
| 1920x1080 RGB | 19.944 [16.901, 28.213] | 15.362 [14.206, 20.999] | 119.047 [112.152, 121.121] | 112.098 [105.917, 117.112] |
| 1920x1080 RGBA | 17.849 [17.159, 20.943] | 14.804 [14.199, 15.599] | 117.520 [114.781, 138.191] | 115.945 [109.436, 121.896] |
| 4000x3000 RGB | 97.894 [95.925, 100.084] | 79.346 [78.059, 83.082] | 655.361 [637.344, 695.694] | 640.798 [621.280, 792.730] |
| 4000x3000 RGBA | 97.950 [95.759, 99.688] | 79.868 [78.290, 82.111] | 680.152 [642.766, 748.239] | 650.315 [634.666, 1010.860] |

This run showed a 1.17-1.30x isolated luminance speedup. Full-calculation
medians improved by 1.01-1.06x, but their spreads overlap and previous
confirmation runs included regressions. The measurements do not establish a
reliable full-hash speedup.

### Dart 3.11.6 recheck

After rebasing onto the pinned Nix flake (Dart 3.11.6), a shorter AOT run with
7 samples measured isolated luminance speedups of 1.16-1.25x. Full-calculate
medians ranged from 0.95x to 1.04x. The 64x64 cases were about 5% slower in
two driver runs. A separate interleaved A/A test showed that this was
measurement noise, not a regression. It compared the baseline, an identical
copy of the production library, and production. Identical copies differed by
up to 3%, and production matched or beat baseline.

## Method and limitations

- Measured on 2026-11-24 with Dart SDK 3.14.1 (rechecked with 3.11.6), macOS 26.7.3, arm64, Apple
  A18 Pro, six logical CPUs and 8 GiB RAM. JIT used `dart run`; AOT used
  `dart compile exe`. This was not a dedicated, frequency-locked machine.
- Inputs were seeded, tightly packed RGB/RGBA buffers at 64x64, 512x512,
  1920x1080 and 4000x3000. No image decoding was included. Isolated conversion
  reused its output allocation; full `calculate` included normal allocations
  and all downstream PDQ work.
- Each case and variant warmed up for at least 500 ms, then collected 11
  interleaved samples with adaptive batches targeting 100 ms. At least one
  complete invocation was measured per sample.
- Startup, compilation, and table initialization were excluded. Cold calls,
  fresh-isolate overhead, grayscale performance and padded-buffer throughput
  were not benchmarked.
- **Android was not measured.** macOS AOT results do not establish performance
  on an Android device or in a Flutter release build; measure representative
  devices before promising an Android-specific improvement.

For correctness, both JIT and AOT compared the actual production kernel's
float32 output bits against the original for all 16,777,216 RGB triples, plus
44 Meta reference inputs and 300 randomized grayscale/RGB/RGBA images with
padding, odd sizes and buffer-view offsets. The reference fixtures and
randomized inputs also compared final hash and quality.

Reproduction commands and benchmark controls are in [README.md](README.md).
