# win-box (English)

Run a **Windows 11 VM with the AMD iGPU passed through**, display it as a window on the Linux
desktop via [Looking Glass](https://looking-glass.io/) — and keep the hard-won knowledge
(kernel driver traps, reset-bug workarounds, ROM handling) as a readable, reusable shell library
plus one small C tool.

> **This is not a universal one-click installer.** It exposes a set of operations that were
> verified on one specific machine as shell functions and thin command wrappers. On different
> hardware or another distribution it will **not** just work: it fails loudly and points at the
> documentation instead of silently guessing.

## Requirements

| | |
| --- | --- |
| Host OS | Debian/Ubuntu family (only this toolchain is targeted; no distro abstraction) |
| Hardware | AMD APU/iGPU (e.g. Granite Ridge), IOMMU available |
| Stack | KVM + libvirt + QEMU + OVMF + swtpm (installed by `winbox host-prep`) |
| Guest | Your own licensed Windows 11 image (not shipped here) |
| Guest driver | AMD Adrenalin **offline** installer (the online installer refuses in passthrough setups) |

## Quick start

```bash
git clone --recurse-submodules <this repo>
cd win-box

scripts/bin/winbox detect --write     # probe hardware → config/win-box.conf
sudo scripts/bin/winbox host-prep     # deps / vfio / initramfs / kernel params (reboot may be needed)
scripts/bin/winbox adopt              # adopt an existing VM (extract its identity into the config)
#   or: scripts/bin/winbox vm-create  # create a new UEFI+TPM2 VM, then install Windows manually
sudo scripts/bin/winbox gpu-attach    # attach the iGPU (ROM + dedicated root port + display mode)
sudo scripts/bin/winbox lg-prepare    # KVMFR module + build the Looking Glass client
sudo scripts/bin/winbox lg-shmem      # shared memory device + the two permission gates
sudo scripts/bin/winbox reset-hook install
scripts/bin/winbox vm start && scripts/bin/winbox lg
```

Everyday use:

```bash
scripts/bin/winbox status             # whole-chain self check (exit code IS the verdict: 0/6/7)
scripts/bin/winbox evidence           # evidence bundle with sha256 manifest
scripts/bin/winbox vm snapshot-save
```

## Design in one screen

**Three layers, strictly downward**: `winbox` (entry) → `scripts/bin/<command>` (one stage per
chain) → `scripts/lib/*.sh` (atomic functions, individually sourceable).
Commands never call each other; shared logic sinks into the library.

**Domain XML is rendered from a template** (`config/templates/domain.xml.in` + fragments).
No XML editing tool, no Python, and the result can be validated offline against libvirt's own
RNG schema. Trade-off, stated up front: *manual `virsh edit` changes are overwritten by the next
render* — change the template instead.

**Unified failure semantics**:

```
✗ <stage>: <reason> → <doc anchor>

0 ok   1 failed   2 usage   3 precondition unmet
4 hardware mismatch   5 needs a human   6 degraded   7 broken (6/7 only from `status`)
```

**No Python.** C is used only where shell is genuinely unsuitable: `src/romtool`
(ROM structure parsing/verification/patching/merging, `make test` with synthetic ROMs).

## Documentation map

| | |
| --- | --- |
| `ARCHITECTURE.md` | topology, the three end-to-end chains, state machines, module map |
| `docs/interfaces/` | CLI + library contracts (commands, failure codes, config keys) |
| `docs/calltrees/` | each chain step by step, including the reset cycle and the LG chain |
| `docs/zh/` | the field record, in Chinese: what broke, what the evidence was, what finally worked |
| `docs/samples/` | sanitized `virsh dumpxml` used by the offline tests |

## Known limitations

- **White blocks on the physical display**: an AMD driver defect on Looking Glass' D3D12 direct
  transfer path. Not fixable from the configuration layer — mitigate with the indirect copy path
  or simply don't plug a monitor into the iGPU.
- **Reset bug**: after a VM shutdown the iGPU is left in a dirty state; requires a real reset
  (this project's libvirt hook) or a host cold boot.
- **Host Secure Boot must be off** (the KVMFR module is unsigned).
- Nothing here is tested on NVIDIA or on dGPU passthrough.

## Not included (on purpose)

VBIOS/BIOS ROMs, Windows images, AMD drivers, VirtIO drivers, Looking Glass installers —
see `.gitignore`. The repo ships extraction and verification tooling instead; those binaries are
either vendor-copyrighted or machine-specific.

## License

GPL-2.0-or-later (see `LICENSE`) — required because the C tool reuses LGMP/KVMFR definitions from
the Looking Glass project, which is GPL-2.0. `third_party/` submodules keep their upstream licenses.
