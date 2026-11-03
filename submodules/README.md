# Submodules

This reference design is published by Opsero under the **MIT license** (see `../LICENSE`). It
takes the RoCE v2 engine from a git submodule:

| submodule | upstream | branch | license |
|-----------|----------|--------|---------|
| `submodules/rocelet` | https://github.com/fpgadeveloper/rocelet | `dev` (releases on `main`) | MIT |

The design instantiates the engine's top level `rocelet_top` (interface:
`submodules/rocelet/docs/interface.md`, register map: `submodules/rocelet/docs/registers.md`)
inside its own module `Vivado/src/hdl/rocelet_sys.sv`. `Vivado/scripts/rocelet_sources.tcl`
adds the files listed in `submodules/rocelet/rtl/rocelet.f` to the Vivado project, and the
MicroBlaze application uses the generated register header `submodules/rocelet/sw/rocelet_regs.h`.
Nothing under `submodules/` is modified by this design.

Clone with the submodule, or fetch it in an existing clone:

```
git clone --recursive https://github.com/fpgadeveloper/qsfp28-fmc-rocelet.git
git submodule update --init --recursive
```

The submodule is pinned to a specific rocelet commit (`git submodule status` prints it). To move
to a newer engine, update it deliberately and rebuild:

```
git -C submodules/rocelet fetch origin
git -C submodules/rocelet checkout <commit>
git add submodules/rocelet
```
