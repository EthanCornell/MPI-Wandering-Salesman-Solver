# ✈️ MPI Travelling-Salesman Solver

> **Author:** I-Hsuan(Ethan) Huang
> **Focus:** Parallel search · MPI · branch-and-bound
> **Fun fact:** Beats the serial reference by **7.7 ×** on an 8-core laptop.

---

## Why does this repo exist?

I wanted a **weekend playground** that checks three boxes at once:

1. Refresh raw MPI muscle-memory (no fancy runtimes, pure `mpirun`).
2. Explore branch-and-bound tricks in a scope small enough to finish.
3. Benchmark a consumer laptop against a university cluster.

So I rewrote my old coursework prototype from scratch and packaged it as a
stand-alone project that anyone can clone, build, and run in ≤ 2 minutes.

---

## Directory tour

| Path                           | What you’ll find                                                                                 |
| ------------------------------ | ------------------------------------------------------------------------------------------------ |
| **`wsp-mpi.c`**                | 350-line, header-only MPI solver — heavily commented.                                            |
| **`input/`**                   | A few 16/17/18-city distance matrices (square **and** triangular).                               |
| **`submitjob.py`**             | Tiny Python 3 helper: generates a PBS script for clusters that speak `qsub` (e.g. CMU Latedays). |
| **`Makefile`**                 | One-liner: `mpicc -O3 -std=c11 -Wall -Wextra -march=native`.                                     |
| **`.github/workflows/ci.yml`** | Smoke-test on Ubuntu 22.04 in ≈10 s.                                                             |

---

## Quick start

```bash
# build
make                       # → ./wsp-mpi

# run locally with 4 ranks (oversubscribe if you have <4 cores)
mpirun --oversubscribe -np 4 ./wsp-mpi input/dist17
```

Example output:

```
Optimal tour cost: 2085   time: 0.04 s   ranks: 8
```

---

## Input formats (both accepted)

### 1 · Square matrix

```
N
d00 d01 … d0N
…
dN0 …      dNN
```

### 2 · Upper-triangular symmetric

```
N
d10
d20 d21
…
dN0 dN1 … dN,N-1
```

The loader auto-detects which style it reads.

---

## Design cheatsheet

| Piece              | Detail                                                                                             |
| ------------------ | -------------------------------------------------------------------------------------------------- |
| **Static seeding** | Rank 0 spawns one Task per *first hop* (`0 → i`).                                                  |
| **DFS stack**      | Heap vector that doubles when full → no seg-faults on deep trees.                                  |
| **Bound**          | `lower_bound` = cost so far + cheapest outgoing edge for every unvisited city (admissible, cheap). |
| **Global best**    | `MPI_Allreduce(MIN)` every 10 k expansions.                                                        |
| **Protocol**       | `TAG_REQ`,`TAG_WORK`,`TAG_NOWORK` — 0.5-round-trip work requests.                                  |
| **I/O**            | Accepts both matrix styles; clear abort for malformed files.                                       |

---

## Performance snapshot

<sub>Apple M1 Pro (8P + 2E) · Open MPI 4.1.5</sub>

| `dist17` | 1 rank | 2 ranks | 4 ranks |  8 ranks |
| -------: | -----: | ------: | ------: | -------: |
| Time (s) |   0.31 |    0.17 |    0.09 | **0.04** |
| Speed-up |    1 × |   1.8 × |   3.3 × |    7.7 × |

*Diminishing returns beyond 8 ranks — root of the tree becomes the bottleneck.*

---

## Cluster usage (optional)

```bash
# generate a PBS script but don't submit
python3 submitjob.py -J -p 24 -a "input/dist18"

# happy? then
qsub latedays-XXXX.sh
```

*Requests one 24-core node, 30 min wall-time.*

---

## Future ideas

* **Smarter bound:** 1-tree / Held-Karp to shrink the search space \~10 ×.
* **Peer work-stealing:** remove the single-point master bottleneck.
* **Checkpointing:** per-worker stack dumps ⇒ resumable long runs.
* **Hybrid GPU:** offload bound computation to CUDA/HIP for >18 cities.

---

## Build & test matrix

| OS           | Compiler | MPI   | Result  |
| ------------ | -------- | ----- | ------- |
| Ubuntu 22.04 | GCC 13   | 4.1.5 | ✔ smoke |

*(Add MPICH, Clang, macOS runners if you care.)*

---

## License

MIT — do anything, just credit.
Distance files © CMU (fair-use for educational samples).

---

### Thanks

* CMU for the original assignment idea + inputs.
* Open MPI developers for an MPI that “just works” on laptops.

Enjoy — and ping me if you squeeze more parallel juice out of it!
