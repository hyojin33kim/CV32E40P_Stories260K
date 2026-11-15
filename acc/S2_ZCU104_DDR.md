# S2 — DDR model figures from ZCU104 documentation (11-15)

Conclusion: keep the sim DDR model defaults (`SIM_DDR_LAT 40`, `SIM_DDR_OUT 8`, `SIM_DDR_BURST 16`,
`SIM_DDR_BW 12.8` B/cycle). At 150 MHz they fall inside the documented ZCU104 range. The result
stays within 8% (ctx1) / 1% (ctx512) of the best swept case if the HP port's read issuing capability is set to ≥ 8
(RDISSUE). The latency has no documented value: it is an estimate until it is measured on the board (⑤).

## Documented figures (facts, with source)
| Item | Value | Source |
|---|---|---|
| PS DDR4 on ZCU104 | 2 GB, 64-bit, 4 × Micron MT40A256M16GE-083E (DDR4-2400), DDRC bank 504 | UG1267 v1.1 (ZCU104 board user guide), "PS-Side: DDR4 Component Memory" |
| DDR peak | 2400 MT/s × 8 B = 19.2 GB/s | UG1267 parts; formula as in the AMD SPA tutorial |
| PL→PS ports for DDR | S_AXI_HP0..3_FPD (AFI_2..5), non-coherent to the FPD main switch and DDR; data width 32/64/128 | PG201 v3.4 "Slave Interface", Table 4-2 |
| HP port sharing | HP1 and HP2 share one DDR controller port → use HP0 or HP3 for the weight stream | AMD Embedded Design Tutorials, SPA "Evaluating High-Performance Ports" |
| Read issuing capability | RDISSUE / WRISSUE 1..16 commands (register = n−1), reset default 4 | UG1085 register description (via the Xilinx wiki "Traffic Shaping of HP Ports on Zynq UltraScale+") |
| Measured system throughput (ZCU102, traffic generators) | ~16 GB/s total over all ports (83% of 19.2) | SPA tutorial (measured example, not a port limit) |

## Mapping to the model at 150 MHz
| Model parameter | ZCU104 basis | Setting / range swept |
|---|---|---|
| `SIM_DDR_BW` | one 128-bit HP port at 150 MHz = 16 B/cycle = 2.4 GB/s; DDR (128 B/cycle at 150 MHz) is not the limit | 12.8 (80%, **assumption**); sweep 12.8 / 14.4 / 16 |
| `SIM_DDR_OUT` | RDISSUE 1..16, reset 4 | 8 (requires RDISSUE ≥ 8); sweep 4 / 8 / 16 |
| `SIM_DDR_LAT` | **not documented**; one board measurement reports HP→DDR4 latency as "high and variable" without a figure | 40 cycles = 267 ns (**estimate**); sweep 30 / 40 / 60 / 100 (200–667 ns) |
| `SIM_DDR_BURST` | AXI4 bursts, 16 × 16 B = 256 B | 16 |

## Sweep (D2, full offload, single forward step; `acc/sweep/zcu104_acc_full_d2/sweep.md`, 72 runs, all bit-exact)
Speedup is relative to the D2 SW baseline with ideal memory (3,041,363 / 13,425,011 cycles).

| ctx | best (L30 OUT16 BW16) | default (L40 OUT8 BW12.8) | RDISSUE 4 (L40 OUT4 BW12.8) | worst (L100 OUT4 BW12.8) |
|---|---|---|---|---|
| 1 | 170,557 (17.83×) | 184,546 (16.48×) | 211,440 (14.38×) | 338,263 (8.99×) |
| 512 | 1,460,440 (9.19×) | 1,474,429 (9.11×) | 1,501,323 (8.94×) | 1,628,146 (8.25×) |

- Latency 30→100 with outstanding 8: +22% at ctx1, +3% at ctx512; with outstanding 16: +10% / +1%.
- Outstanding 4 (the reset default) is the one setting that matters: +15% at ctx1, L40.
- Bandwidth 12.8→16 B/cycle: ≤ 7%.

## Unverified / what reverses this
- Real HP→DDR4 latency on ZCU104 and how much it varies (refresh, PS traffic) → measure at ⑤. If it is above ~100 cycles
  (667 ns) *and* RDISSUE cannot be raised, ctx1 drops below 9× and the accelerator needs deeper prefetch.
- The 80% sustained port efficiency is an assumption. The SPA numbers are for many ports on ZCU102.

Sources: [UG1267 PS-side DDR4](https://www.manualslib.com/manual/1475689/Xilinx-Zcu104.html?page=24),
[PG201 Slave Interface](https://docs.amd.com/r/3.4-English/pg201-zynq-ultrascale-plus-processing-system/Slave-Interface),
[SPA: Evaluating High-Performance Ports](https://xilinx.github.io/Embedded-Design-Tutorials/docs/2020.2/build/html/docs/SPA-UG/docs/6-evaluating-high-performance-ports.html),
[Traffic Shaping of HP Ports](https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/688128001/Traffic+Shaping+of+HP+Ports+on+Zynq+UltraScale),
[PS-PL AXI interfaces measurement](https://j-marjanovic.io/exploring-the-ps-pl-axi-interfaces-on-zynq-ultrascale-mpsoc.html).
