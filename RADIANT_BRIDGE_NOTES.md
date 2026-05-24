# Docker-Aware Radiant Bridge (Task 1.3a)

This tree's `radiant.sh` and `radiant_cmd.sh` have been replaced with
Docker-aware wrappers that delegate to a local Radiant install running
inside the `radiant:2025.2.1-ipgen` container (eyecrow flow,
`fpga/docker/radiant/` in the parent eyecrow repo). The originals are
preserved as `radiant_native.sh` and `radiant_cmd_native.sh` for the
Linux-host case.

## Why

prjoxide was written for the Diamond/Radiant 3.x era, expecting a native
`~/lscc/radiant/3.0` install and a `lapie` Tcl wrapper. On Apple Silicon
Macs (mini0n, funi0n) Lattice ships Radiant only as the Docker image we
already use for the eyecrow CLGN build flow, so the host bridge is needed.

## Sanity check

```
$ cd $(prjoxide-root)
$ echo "puts BRIDGE_OK" | ./radiant_cmd.sh radiantc
--- Lattice Radiant Software (64-bit) 2025.2.1.321.0
...
```

## What works

- `radiant.sh <PART> <basename.v>` — drives `sv2udb`/`synthesis`/`postsyn`/
  `map`/`par`/`bitgen` inside the container. Verified end-to-end on
  LIFCL-33-WLCSP84: produced a valid 660 KB bitstream
  (IDCODE 0x010FA043 ↔ devices.json `idcode: 17801283`).
- `radiant_cmd.sh <tool> [args]` — forwards `bstool`, `radiantc`, etc.

## What does NOT work (Diamond → Radiant 2025.2.1 API drift)

The fuzzers expect Diamond-era semantics that Radiant 2025.2.1 does not
provide. These are blockers for Task 1.3 fuzzer extraction:

### 1. `lapie` is unavailable

Radiant 2025.2.1 ships only `radiantc` + `pnmainc` (both vanilla Tcl
interpreters without the Diamond `lapie` extensions). The Diamond UDB
exploration commands the prjoxide harness calls (`des_read_udb`,
`get_node_data`, …) are **not registered** in `radiantc`. Comprehensive
search of `/opt/lscc/radiant/2025.2.1` finds no `lapie` binary.

`radiant_cmd.sh` returns exit 127 with a pointer comment when invoked
with `lapie` as the tool argument, so failures are loud rather than
silent.

Fuzzers affected:
- `fuzzers/LIFCL/110-global-structure` (whole script is `lapie.get_node_data`)
- `fuzzers/LIFCL/050-cib-special`
- `fuzzers/LFCPNX/110-global-structure`
- everything that imports `util/common/lapie.py`

### 2. `sv2udb` does not auto-instantiate Diamond IP primitives

The 100-ip-base fuzzer uses a structural-Verilog (`STRUCT_VER=1`) flow
that places an IP cell via `\dm:primitive`/`\dm:site` attributes on an
empty module instantiation. Radiant 2025.2.1's `sv2udb` accepts the
attributes but emits `WARNING <1025001> - instantiating unknown empty
module 'PLL_CORE'` and produces a bitstream **without** the IP-config
bits. As a result `Chip.get_ip_values()` returns an empty list and the
`assert len(ipv) > 0` fires.

This is API drift in `sv2udb`'s IP-toolchain bridge (Diamond had a
single PNR + IP attribute path; Radiant has split out Synplify + ipgen).
Verified end-to-end: a LIFCL-33 IPADDR33 build runs cleanly through
sv2udb → bitgen, produces a valid bitstream, but no IP frames.

Fuzzers affected:
- `fuzzers/LIFCL/100-ip-base` (the only Task 1.3a target other than 110)
- likely the IP-routing/IP-config fuzzers in Task 1.3b (130/131)

### 3. `\db:package ="QFN72"` literal in `ip.v`

The original `ip.v` template hardcodes `QFN72`, which Radiant 2025.2.1
rejects with `ERROR <1010506> - Invalid package 'QFN72'`. For LIFCL-33
this was worked around by adding a separate `ip_33.v` with
`\db:package ="WLCSP84"`. For LIFCL-17 the original template would need
similar treatment if anyone tries to re-run that cfg.

## Recommended path

Either:

(a) Provide a Diamond install / image alongside Radiant 2025.2.1 (Diamond
has `lapie` and the Diamond-era `sv2udb` semantics). prjoxide was
historically pinned to Diamond ≥ 3.10.
(b) Re-author the `lapie`-dependent fuzzers to extract the same data via
modern Radiant Tcl + bstool dumps (significant effort, deferred).
(c) Statically derive `globals.json` + `baseaddr.json` from datasheet
clock-tree topology + bstool-observed IP frame regions (the Task 1.2
placeholder approach, refined). Lowest-fidelity but unblocking.

For now, `globals.json` and `baseaddr.json` retain the Task 1.2
placeholders. `bba-export LIFCL` still runs cleanly (183.8 MB output).
