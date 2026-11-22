# DDR4 channel efficiency model (first-order, unvalidated; see ddr/ddr_model.py)

DDR4-2400 17-17-17, 1 channel x 64 bit (19.2 GB/s peak), page 8 KB/bank, open page, lookahead window W.
Efficiency = streamed bytes / (time x peak). Two masters read separate 1 MiB regions.

## mapping `bgint`

| interleave quantum | 1 master | 2 masters, W=16 | 2 masters, W=4 | 2 masters, W=64 |
|---|---:|---:|---:|---:|
| 64 B | 95.7% | 12.7% | 12.7% | 12.7% |
| 128 B | 95.7% | 23.9% | 23.9% | 23.9% |
| 256 B | 95.7% | 27.4% | 27.4% | 27.4% |
| 512 B | 95.7% | 52.1% | 52.1% | 52.1% |
| 1 KB | 95.7% | 67.6% | 67.5% | 67.6% |
| 2 KB | 95.7% | 79.4% | 79.4% | 79.4% |
| 4 KB | 95.7% | 86.9% | 86.9% | 86.9% |
| 8 KB | 95.7% | 91.4% | 91.4% | 91.4% |
| 16 KB | 95.7% | 93.9% | 93.9% | 93.9% |
| 32 KB | 95.7% | 95.1% | 95.1% | 95.1% |
| 64 KB | 95.7% | 95.7% | 95.4% | 95.7% |

## mapping `rowseq`

| interleave quantum | 1 master | 2 masters, W=16 | 2 masters, W=4 | 2 masters, W=64 |
|---|---:|---:|---:|---:|
| 64 B | 64.1% | 6.9% | 6.9% | 6.9% |
| 128 B | 64.1% | 13.7% | 13.7% | 13.7% |
| 256 B | 64.1% | 25.2% | 25.2% | 25.2% |
| 512 B | 64.1% | 36.5% | 36.5% | 36.5% |
| 1 KB | 64.1% | 46.9% | 46.9% | 46.9% |
| 2 KB | 64.1% | 54.6% | 54.6% | 54.6% |
| 4 KB | 64.1% | 59.5% | 59.5% | 59.5% |
| 8 KB | 64.1% | 62.3% | 62.3% | 62.3% |
| 16 KB | 64.1% | 64.0% | 63.4% | 64.0% |
| 32 KB | 64.1% | 64.0% | 63.5% | 64.0% |
| 64 KB | 64.1% | 64.0% | 63.8% | 64.0% |

## page size sensitivity (mapping bgint, W=16, 2 masters)

| quantum | page 2 KB | page 4 KB | page 8 KB |
|---|---:|---:|---:|
| 128 B | 23.9% | 23.9% | 23.9% |
| 1 KB | 68.5% | 67.9% | 67.6% |
| 8 KB | 93.1% | 91.9% | 91.4% |
| 32 KB | 95.7% | 95.7% | 95.1% |
