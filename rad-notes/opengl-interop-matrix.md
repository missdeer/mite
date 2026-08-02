# OpenGL / DirectComposition Interoperability Matrix

Evidence date: 2026-08-02

## Result Definitions

- **Direct**: the runtime log confirmed the WGL/D3D11 bridge and a captured Mostty window remained usable through movement and resize exercises.
- **Fallback**: the bridge was unavailable or failed and the baseline WGL renderer remained usable.
- **Not tested**: matching current-driver hardware was unavailable; no support result is inferred.

## Renderer Output

| Required vendor target | Tested hardware and driver | Result | Observed evidence |
| --- | --- | --- | --- |
| NVIDIA | GeForce RTX 4060 Ti, Windows driver `32.0.15.9186` | **Direct** | Bridge activation logged with no fallback; terminal capture passed; 40 window moves passed; four resize/recreate cycles passed. |
| AMD 20.x+ / current | No matching hardware available | **Not tested** | External current-driver AMD run is still required. |
| Intel Arc | No matching hardware available | **Not tested** | The installed Iris Xe is not substituted for the required Arc result. |

## Fallback Evidence

- Unit tests bind the presentation rule to intent: only an active bridge selects DirectComposition; untried, unavailable, and failed states select baseline WGL.
- Capability, setup, resize, lock, unlock, and presentation errors all route through the same permanent process-lifetime fallback.
- A driver-level fallback was not forced on the NVIDIA test machine; it remains part of the external AMD and Intel Arc runs.

## Font Handoff

- The tested direct path covers the completed OpenGL frame presented through DirectComposition.
- Glyph and tab-bar handoff remains CPU staging. The process font-service device is intentionally single-threaded, while the Khronos D3D11 interoperability contract requires a multithread-capable device.
- The bridge therefore owns a separate eligible D3D11 presentation device and does not change font-service ownership or behavior.
