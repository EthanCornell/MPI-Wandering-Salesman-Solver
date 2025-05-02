
# ✈️ MPI Travelling-Salesman Solver

> **Author:** I-Hsuan (Ethan) Huang  
> **Tech:** C · MPI · branch-and-bound search  
> **Fun fact:** Beats the serial baseline by **7.7 ×** on an 8-core M1 Pro.

---

## 0 · Project goals

* **Refresh** raw MPI skills (no fancy runtimes; just `mpirun`).  
* **Experiment** with pruning heuristics in a bite-size ≤ 18-city space.  
* **Benchmark** laptop vs. campus cluster in under five minutes.

---

## 1 · Directory tour

| Path | What you’ll find |
|------|------------------|
| **`wsp-mpi.c`** | 350-line single-file solver (extensively commented). |
| **`run_job.sh`** | Smart wrapper – runs locally **or** submits via `qsub` when PBS is available. |
| **`submitjob.py`** | Generates PBS scripts programmatically (used in coursework). |
| **`input/`** | Distance files (`dist16/17/18`, triangular & square). |
| **`sqrt3/`** | Tiny demo app from the course hand-out (left unchanged). |
| **`Makefile`** | One-target build (`wsp-mpi`) with `-O3 -Wall -Wextra`. |
| **`.github/workflows/ci.yml`** | Smoke test on Ubuntu 22.04. |

---

## 2 · Building & running (`wsp-mpi`)

### 2.1 Build

```bash
make            # produces ./wsp-mpi
````

### 2.2 Command-line interface

```
./wsp-mpi <distance-file>
```

*Exactly one argument* – the path to a square **or** upper-triangular matrix.

### 2.3 Local run examples

```bash
# 4 ranks on a 4-core laptop
mpirun -np 4 ./wsp-mpi input/dist17

# 24 ranks on an 8-core laptop (time-sharing each core)
mpirun --oversubscribe -np 24 ./wsp-mpi input/alt-dist18
```

Typical output:

```
Optimal tour cost: 2085   time: 0.041 s   ranks: 8
```

| Field                 | Meaning                           |
| --------------------- | --------------------------------- |
| **Optimal tour cost** | Minimum path length found.        |
| **time**              | Wall-clock seconds (`MPI_Wtime`). |
| **ranks**             | MPI processes used (`-np`).       |

---

## 3 · Helper scripts – usage cheatsheet

| Script             | Purpose                                                                                                    | Example                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **`run_job.sh`**   | One-liner wrapper that <br>• runs `mpirun` locally **or** <br>• submits a PBS job via `qsub` if available. | `./run_job.sh 2 12 tsp.2x12.log` <br>*(2 nodes × 12 ranks each, log → file)*     |
| **`submitjob.py`** | Generates a PBS script and (optionally) calls `qsub`.                                                      | `python3 submitjob.py  -p 24  -a "input/dist18"`<br>*(24 ranks, default 1 node)* |

### 3.1 `run_job.sh` arguments

```
./run_job.sh <nodes 1-4> <ppn 1-24> <stdout-file>
```

* If `qsub` **exists** → submits `latedays.qsub` with the requested resources.
* Else → executes `mpirun -np <nodes·ppn>` locally and writes combined stdout/stderr to `<stdout-file>`.

### 3.2 `submitjob.py` flags (Python 3)

| Flag       | Meaning                                              | Default    |
| ---------- | ---------------------------------------------------- | ---------- |
| `-J`       | *Just* generate the script (skip submission)         | off        |
| `-p N`     | Total MPI ranks (`mpirun -np N`)                     | 1          |
| `-a "ARG"` | Argument string for program (e.g., `"input/dist17"`) | ""         |
| `-s NAME`  | Root name of the script file                         | `latedays` |
| `-d N`     | Digits for random suffix                             | 4          |

Example that only **generates** a script:

```bash
python3 submitjob.py -J -p 32 -a "input/dist18"
# → latedays-1234.sh  (inspect; run qsub manually if desired)
```

---

## 4 · Input file formats (auto-detected)

### Square (full) matrix

```
N
d00 d01 … d0N
d10 d11 … d1N
…
dN0 …      dNN
```

### Symmetric upper-triangular

```
N
d10
d20 d21
…
dN0 dN1 … dN,N-1
```

Malformed input aborts with a clear message.

---

## 5 · Performance snapshot

<sub>M1 Pro 8P+2E · Open MPI 4.1.5</sub>

| `dist17` | 1 rank | 2 ranks | 4 ranks |  8 ranks |
| -------: | -----: | ------: | ------: | -------: |
| Time (s) |   0.31 |    0.17 |    0.09 | **0.04** |
| Speed-up |    1 × |   1.8 × |   3.3 × |    7.7 × |

> After 8 ranks the upper tree levels saturate; extra ranks fight over crumbs.

---

## 6 · Interpreting results

* **Cost sanity:** Check against `input/distances` or staff solutions.
* **Timing sanity:** 17-city local run ≈0.05 s (–O3); cluster 24 cores ≈0.01 s.
* **Scaling sanity:** Expect \~8 × on 24 cores; perfect linear is impossible.

---

## 7 · Future work

* Stronger 1-tree / MST bound (×5–10 pruning).
* Peer work-stealing (remove master bottleneck).
* Periodic checkpoint & resume.
* Offload bound kernel to GPU.

---

## 8 · CI matrix

| OS           | Compiler | MPI | Result  |
| ------------ | -------- | --- | ------- |
| Ubuntu 22.04 | GCC 13   | 4.1 | ✔ smoke |

(Add MPICH / Clang / macOS runners if you fancy.)

---

## 9 · Appendix · What the `sqrt3` demo is for 🧐
*A tiny “hello-MPI” benchmark shipped with the course starter kit.*

The goal is **not** to solve anything useful; `sqrt3` simply burns CPU in a
predictable way so you can:

1. Verify that your MPI tool-chain (`mpicc`, `mpirun`) works.  
2. Check oversubscription behaviour and per-core throughput on different
   machines.  
3. Have a safe sandbox to tweak compilation flags or profiling tools without
   touching the real TSP solver.

When you run

```bash
mpirun --oversubscribe -np 24 ./sqrt3
````

each MPI rank executes a very long floating-point loop that repeatedly
approximates √3, purely to burn CPU.  At the end it calls `MPI_Wtime()` and
prints:

```
elapsed time for proc <rank> : <seconds>
```

Example:

```
elapsed time for proc 11: 19.423469
elapsed time for proc  7: 19.399574
…
elapsed time for proc  3: 19.422991
```

### Why all times ≈ 19 s?

* You launched **24 ranks** but your laptop almost certainly has **fewer than
  24 hardware cores**.
* The `--oversubscribe` flag tells Open MPI to time-share the CPU, so each
  rank only gets a slice → the wall-time stretches to \~19 s.

Run with a rank count that matches your physical cores and the numbers fall
dramatically (e.g. 6–8 s on an 8-core machine):

```bash
mpirun -np 8 ./sqrt3
```

### How to read the output

| What to look for              | Interpretation                                                    |
| ----------------------------- | ----------------------------------------------------------------- |
| **All ranks within a few ms** | Good – perfectly balanced toy workload.                           |
| **One rank much slower**      | The OS throttled / migrated that process or the machine was busy. |
| **Times > course reference**  | You’re oversubscribed or compiled without `-O3`.                  |

This program is *only* a sanity check; your real performance exploration
happens with `wsp-mpi`.  Still, `sqrt3` is handy for:

* **Verifying** your MPI install & `mpirun` flags before running bigger jobs.
* **Measuring** raw per-core throughput differences between laptop and cluster nodes.
* **Profiling sandbox** – edit `sqrt3.c` freely; nothing in the main solver depends on it.


---
## License

MIT — use, hack, share.
Starter inputs © Carnegie Mellon University.

---

### Thanks

* CMU 15-418/618 staff for the original assignment & inputs.
* Open MPI devs for shipping a runtime that “just works”.

Enjoy — and ping me if you squeeze more parallel juice out of it!
