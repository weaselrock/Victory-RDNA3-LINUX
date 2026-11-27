# Victory-RDNA3-LINUX

A **Linux-targeted fork** of
[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)
(based on [VIctory](https://github.com/Marvisak/VIctory)), focused on running
an Xbox Series title on **Linux through Proton / Wine + vkd3d-proton on AMD
RDNA 3 GPUs (Mesa RADV)**, including 32 GB RAM machines.

See **[docs/proton.md](docs/proton.md)** for full Linux/Proton requirements,
cross-building with `cargo-xwin`, the patched `wineserver`, and every Wine/RADV
fix included here. All Wine/Proton workarounds activate automatically under
Wine (`wine_get_version`) and leave Windows behavior unchanged.

### Linux / Proton additions over upstream

- **vkd3d-proton & RADV shader/pipeline fixes**: single-latch loop
  normalization (`VICTORY_ONE_LATCH`), compute pipeline wait for once-only
  dispatches (`VICTORY_COMPUTE_WAIT`), descriptor-table integer slot words
  (`VICTORY_TABLE_SLOT_WORDS`), and raw 16-bit typed loads across barriers on
  RADV (`VICTORY_RAW_TYPED_LOADS`).
- **GPU & memory stability under Wine**: safe descriptor publication
  (`VICTORY_PUBLISH_SAFE`), zero-address and null-buffer guards
  (`VICTORY_NULL_BUFFER_ZEROS`), hardened texture read-back
  (`VICTORY_FETCH_MARK`), runtime placeholder hole tracking to avoid per-frame
  `VirtualQuery` lock contention (`VICTORY_WINE_HOLES`), and placed Vulkan
  memory for Port 1 (`VICTORY_PORT_PLACED=1` via the companion implicit layer,
  placing the 185 MB constants heap directly at the title's address).
- **PC mouse + keyboard input**: opt-in `VICTORY_MOUSE=1` camera/trigger mouse
  support (see [docs/README-fxceless.md](docs/README-fxceless.md)).

## The goal

**A stable 30 fps or more without ray tracing, then as high a frame rate and as
low frame times as the PC allows**, targeting Linux (Proton + Mesa RADV) on AMD
RDNA 3 (RX 7900 XTX) and PCs with 32 GB (later 16 GB) of RAM.

The way there is **porting, not emulating**: patching the title's renderer so it
behaves the way a PC renderer does, rather than having the layer watch and copy
the console's shared memory every frame. Shaders are translated ahead of time
into a versioned store that is kept between builds. Ray tracing stays optional
and off by default. The picture comes after the frame rate: texture pop-in and
lighting that is too bright or too dark when walking indoors are next in line.

**This repository contains no game files, code or assets.** You need your own
copy of the game. It is not affiliated with or endorsed by the game's developer
or publisher.

## Where it stands (2026-11-27)

Measured on Linux: kernel 7.0, AMD Ryzen 5 7600X (6c/12t), 32 GB RAM, Radeon
RX 7900 XTX 24 GB, standalone Mesa RADV 26.3.1, `vkd3d-proton 3.2.0`, patched
view-tree `wineserver`, `diag` build (`--features diagnostics`, commit
`e8e8c78`), Series X profile, ray tracing off, with `VICTORY_PORT_CONSTANTS=1`,
`VICTORY_PORT_PLACED=1`, `VICTORY_LAND_THREADS=6`, and `VICTORY_MOUSE=1`.

| | |
|---|---|
| Boat level, idle (~4,015 draws/frame, 100 s steady window) | **22.8 fps average** (20.9–23.6 fps), **43.9 ms/frame** (42.4–47.8 ms: 30.3 ms preparing, 0.0 ms GPU wait, 14.0 ms copying back) |
| Cutscene (~1,580 draws/frame) | up to **29.4 fps** (34.0–34.7 ms/frame) |
| Port 1 placed heap (`VICTORY_PORT_PLACED=1`) | 1 heap placed (185 MB), 0 fallbacks |
| Shaders the title uses that translate | all of them (25,790 of 25,985; the rest are unused geometry shaders) |
| Memory (12.6 min run on 32 GB host) | **~9.3 GiB RSS + ~3.4 GiB swap (~12.7 GiB steady)**; peak 11.8 GiB RSS / 14.4 GiB RSS+swap |
| Upstream Windows baseline (2026-11-26, i9-12900K, 64 GB, 7900 XTX) | ~19 fps (~53 ms/frame) with renderer patches 1+2; ~35 GB private memory |

It started at 280 ms a frame in the same scenes on upstream four days earlier.
Note that the `diag` build includes `--features diagnostics` timing overhead; a
plain `--release` build removes that overhead.

### Renderer patches & tuning switches

| Switch | What it does |
|---|---|
| `VICTORY_PORT_CONSTANTS=1` | The title's 174–185 MB constants heap is read by the card where the title writes it: no uploads, no fills |
| `VICTORY_PORT_PLACED=1` | Places the Port 1 heap directly at the title's virtual address (requires the placed-memory Vulkan layer on Linux/vkd3d-proton) |
| `VICTORY_PORT_DESCRIPTORS=1` | The title's descriptor-table stores are patched (byte-checked) to report the slots they write, instead of a scan of ~600,000 slots a frame |
| `VICTORY_LAND_THREADS=6` | Overrides relay landing worker count (default `threads / 4`; 6 threads on a 6c/12t CPU cuts copy-back time) |

What is known to be wrong:

- Trees, signs and far objects flicker in the distance in some places.
- Lighting is too bright or too dark after walking indoors, until the title has
  run for a while; rooms with little direct light are too dark without `-RayTracing`.
- Textures of what just came into view appear late while the title streams.
- The first run of a new build stutters while the driver makes pipelines
  (`victory warm` makes them ahead).
- Recording a frame in the world makes the title's own watchdog end it.

## How to run it

### Linux (Proton / Wine + Mesa RADV — primary target)

Follow **[docs/proton.md](docs/proton.md)** for full setup details (Proton
Experimental, the view-tree `wineserver` patch, `d3dcompiler_47.dll` build
10.0.26100, and `cargo-xwin`), or use the helper scripts under `scripts/linux/`:

```bash
git clone https://github.com/weaselrock/Victory-RDNA3-LINUX
cd Victory-RDNA3-LINUX

# Optional one-time setup for speed and VK_EXT_descriptor_heap on RDNA 3:
bash scripts/linux/build-fast-wineserver.sh
bash scripts/linux/build-radv.sh

# First run (supply Microsoft's 64-bit d3dcompiler_47.dll 10.0.x):
D3DCOMPILER_DLL=/path/to/d3dcompiler_47.dll \
  bash scripts/linux/run-victory-lowmem.sh --game-dir /path/to/dump

# Later runs:
bash scripts/linux/run-victory-lowmem.sh --game-dir /path/to/dump
```

Helper scripts included in `scripts/linux/`:
- `run-victory-lowmem.sh`: builds with `cargo-xwin`, sets up the Proton prefix,
  and launches with `--game-dir <dir>` (or `--exe <path>`, or `GAME_DIR`),
  memory limits, and per-run logs (`warm` precompiles recorded pipelines).
- `build-fast-wineserver.sh`: builds a patched Proton copy with the Wine bug
  60868 view-tree `wineserver` (`wineserver-view-tree.patch.txt`).
- `build-radv.sh`: builds standalone Mesa 26.3.1 RADV without touching the
  system driver.
- `profile-victory.sh` / `profile-victory-calls.sh`: Linux `perf` CPU and
  syscall profilers for a running session.

### Windows (upstream target)

You need Windows 10/11 x64, a CPU with AVX2, a Direct3D 12 GPU with shader
model 6.6 and mesh shaders, Rust (the toolchain is pinned), the MSVC build
tools, and your own dump of the title.

```powershell
git clone https://github.com/weaselrock/Victory-RDNA3-LINUX
cd Victory-RDNA3-LINUX
copy victory.example.toml victory.toml      # then set your paths, outside this folder
cargo build --locked --profile diag -p victory --features diagnostics
scripts\play.ps1 -Exe <path of your copy's executable>
```

`scripts\play.ps1 -Safe` leaves out the newest, faster ways; try it first when
something is wrong. `-RayTracing` turns the title's ray-traced indirect light on.

On a hybrid-graphics PC, the runtime and offline pipeline checks prefer a
high-performance adapter with Shader Model 6.6. The runtime logs its adapter
name, PCI vendor and device IDs, and dedicated VRAM. Set
`VICTORY_D3D12_ADAPTER` to a zero-based DXGI index or part of the adapter's
name to select it explicitly. With the launcher, pass
`-More @{VICTORY_D3D12_ADAPTER='NVIDIA'}`.

Before the first run, ahead of time (both can be stopped and go on later):

```powershell
target\diag\victory.exe shaders <the shader archives>   # every shader translated, minutes
target\diag\victory.exe warm --used                     # pipelines earlier runs drew with, for a new driver or build
```

Commands, debugging switches and upstream's own description:
[docs/README-fxceless.md](docs/README-fxceless.md). Every `VICTORY_...` switch is
described in a comment where it is read.

## What is different here

In short; the reasons and the measurements are in [docs/findings.md](docs/findings.md).

- **List calls are written down, not carried out, on the title's threads**
  (`VICTORY_THIN`): eight threads of ours translate them.
- **Submissions are prepared by a thread of ours and joined**
  (`VICTORY_ASYNC_SUBMIT`, `VICTORY_JOIN_PARTS`), with what can be spread over
  threads spread: refreshes, compares (AVX2), descriptor records, landings.
- **What shaders wrote comes back beside the write guards**, by the dwords that
  changed, on a thread of its own (`VICTORY_RELAY`, `VICTORY_LAND`).
- **Buffer fills that need bytes still on the card are done on the card**
  (`VICTORY_CARD_STEPS`) instead of waiting for it.
- **The title's writes are caught more cheaply**: one view opened at a fault,
  blocks that rest, places in the title's code that look before they write.
- **Textures go up on a copy queue of their own** and a slot shows one only after
  its upload ran, which also ended a device loss that came every 15 minutes or so.
- **Boats float**: textures that shaders write and the title's CPU reads go back
  to title memory (from fxceless and Geckomacabre, on by default here).
- **Frame record and replay** with per-pass times and shader variants compared
  turn by turn ([docs/replay.md](docs/replay.md)).

## Credits

This is a tree of other people's work with more on top. The history is kept, and
commits taken from elsewhere name the commit and its author.

- **[avatarmanz/VIctory-7900XTX](https://github.com/avatarmanz/VIctory-7900XTX)**:
  the direct upstream AMD RDNA 3 fork this Linux-targeted fork is built on.
- **[VIctory](https://github.com/Marvisak/VIctory)** by Marvisak and its
  contributors: the loader, the runtime services, the Direct3D 12 back end and
  the shader recompiler.
- **[fxceless/victory-fork](https://github.com/fxceless/victory-fork)**: the fork
  this one started from, and the people whose pull requests it carries.
- **[DexNom/VIctory](https://github.com/DexNom/VIctory)**: ray tracing fixes,
  cube gradients, sparse textures.
- **[Belobug/VIctory-Belobug-AMD](https://github.com/Belobug/VIctory-Belobug-AMD)**:
  the ambient light idea, pipeline workers, and work by romainhedouin.
- **[FQY55kai/ZJOU-VICTORY](https://github.com/FQY55kai/ZJOU-VICTORY)**.
- **[myokex/victory-amd](https://github.com/myokex/victory-amd)**: the guard over
  every view of a page (with Spexivus, joroyt and tightfall), and Joshua Odom's
  reads into title memory.
- **Geckomacabre** and **cxy0072019-sketch**: the texture read-back.
- **[XCL](https://github.com/ivall/xcl)** (GPL-2.0-only) was read for how the same
  title behaves under another layer; no code of it is here.
- This fork's changes were made with [Claude Code](https://claude.com/claude-code).

## License

GPL-3.0-or-later, as VIctory. See [LICENSE](LICENSE); the one file that is not
covered is named in [docs/asset-policy.md](docs/asset-policy.md).
