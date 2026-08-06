# Update libghostty-vt and Zig

## Version delta

- Current ghostty: `fdbf9ff3a31d7531b691cb49c98fc465a1a503a0`
  (2026-06-15)
- Target ghostty: `ec58fbc6a2da89f6d17381d56ef316f29dbf789b`
  (2026-08-06)
- Toolchain: Zig `0.15.2` -> `0.16.0`
- Crash fix: `9ed61428daa9f15b2dc89e73f9fe0d16d3a6bb71`
  (`libghostty-vt: spacer-tail handling needs to respect slow runtime safety`)

GitHub's compare response reaches its 300-file limit for this 642-commit
range. The VT assessment therefore uses a local package-to-package diff of
the two exact Zig package hashes, scoped to `src/terminal/`, plus the target
public `src/lib_vt.zig` export surface.

## VT file stats and impact

| File/group | Additions | Deletions | mostty impact |
| --- | ---: | ---: | --- |
| `Terminal.zig` | 3548 | 961 | Breaking: `init` gains `std.Io`, scrollback option is renamed, and `resize` takes a value struct. Includes the wide-cell crash fix. |
| `stream.zig` | 1259 | 71 | Breaking: `initAlloc` is replaced by `init(.{ .allocator, .handler })`; additive `print_slice` support. |
| `stream_terminal.zig` | 1374 | 199 | Additive effect callbacks have null defaults in `.readonly`; handler state grows. Existing callback signatures remain compatible. |
| `PageList.zig` | 6262 | 1448 | Internal pin/page redesign. Potentially breaking because rendering, selection, and URL hover inspect pins/pages directly; compile and behavioral gates required. |
| `Screen.zig` | 2074 | 573 | Resize, selection, cell, and Kitty image behavior changes; compile and behavioral gates required. |
| `Selection.zig` | 101 | 29 | Existing `Selection.init` and containment use must be rechecked. |
| Kitty graphics files | 2450 | 538 | Storage/image/placement changes affect mostty's Kitty renderer and protocol tests. |
| `color.zig` / `style.zig` | 357 | 82 | Public color/style exports remain present; compile gate required. |
| `lib_vt.zig` / `terminal/main.zig` | additive exports | none removed from mostty's list | `Terminal`, stream, cell, selection, pin, coordinate, style, color, sys, and Kitty exports remain available. |
| Other VT implementation/tests | large additive delta | mixed | Not referenced directly by mostty; covered by dependency compilation and mostty behavior tests. |

Build wiring changed to require Zig 0.16 and default dependency builds to
lib-vt mode. The `ghostty-vt` module remains available. SIMD support remains
part of the module and must compile with the MSVC ABI.

## Implementation

1. Update the repository's minimum Zig version, CI version, architecture/build
   documentation, and update-vt runbook to 0.16.0.
2. Use Zig `fetch --save` to update the ghostty URL and package hash.
3. Adapt only referenced API changes reported by the compiler.
4. Remove the custom pre-print cell repair introduced by mostty commit
   `8abb8e7`; retain intent-level tests that overwrite both a wide head and
   spacer tail through the normal upstream terminal stream.

## Verification and success criteria

- `build.zig.zon` pins target `ec58fbc6` with the computed package hash.
- No custom wide-cell repair remains in mostty.
- Regression tests overwrite a wide head and spacer tail without panic and
  assert the resulting plain text.
- `zig build test` passes with no skipped tests hidden.
- `zig build` passes using Zig 0.16.0 and `D:\zig-cache`.
- Fresh `Mostty.exe` reaches the Win32 message loop without an early crash.
- Final diff contains only the dependency/toolchain migration and required API
  adaptations.
