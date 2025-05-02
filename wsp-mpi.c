/*--------------------------------------------------------------------*
 *  Message-Passing WSP
 *
 *  wsp-mpi.c  —  Branch-and-bound Travelling-Salesman solver
 *                using MPI across ≤ 18 cities.
 *
 *  Build :   mpicc -O3 -std=c11 -Wall -Wextra -march=native -o wsp-mpi wsp-mpi.c
 *  Run  :    mpirun [--oversubscribe] -np <P> ./wsp-mpi input/dist17
 *
 *  The program accepts **either**:
 *      • full N × N distance matrices  (289 ints for N=17)
 *      • symmetric upper-triangular   (N·(N-1)/2 ints  = 153 for N=17)
 *
 *  Rank-0 seeds one task per “first hop” city and hands them
 *  out on demand.  Workers depth-first search their sub-tree
 *  with branch-and-bound.  Global best cost is synchronised
 *  every REDUCE_INTERVAL expansions using MPI_Allreduce().
 *--------------------------------------------------------------------*/

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* ---------- Tunables & limits -------------------------------------- */
#define MAX_N            18      /* Assignment never exceeds 18 cities   */
#define MAX_PATH         MAX_N   /* longest path prefix we store         */
#define START_DEPTH       1      /* how deep to expand before seeding    */
#define REDUCE_INTERVAL 10000    /* node-expansions between Allreduce    */

/* ---------- MPI message tags  -------------------------------------- */
enum { TAG_REQ = 1, TAG_WORK, TAG_NOWORK };

/* ---------- Work unit ------------------------------------------------
 * A Task is the root of a search sub-tree.  We send it as a POD struct
 * (array of ints), so size must not exceed a few KB. */
typedef struct {
    int depth;           /* length of prefix -- includes city 0          */
    int cost;            /* cumulative cost of that prefix               */
    int city;            /* last city in the prefix                       */
    int visitedMask;     /* bitmask: 1 << i => city i already visited     */
    int path[MAX_PATH];  /* explicit prefix so we can reconstruct tours   */
} Task;

/* ---------- Globally-broadcast data -------------------------------- */
static int  N;                        /* number of cities               */
static int  dist[MAX_N][MAX_N];       /* distance matrix                */

/* ---------- Global best solution (replicated on all ranks) ---------- */
static int  best_cost;                /* current global optimum cost    */
static int  best_path[MAX_PATH + 1];  /* full optimal tour incl. return */

/* ---------- DFS stack node ----------------------------------------- */
typedef struct {
    int city, depth, cost, visitedMask;
    int path[MAX_PATH];
} Node;

/* --------------------------------------------------------------------
 *  lower_bound()  —  cheap admissible heuristic:
 *  For every unvisited city, add its cheapest outgoing edge.
 *  Ensures we never underestimate → safe pruning.                      */
static inline int lower_bound(int cost, int mask)
{
    int lb = cost;
    for (int i = 0; i < N; ++i) {
        if (mask & (1 << i)) continue;          /* already visited */
        int best = INT_MAX;
        for (int j = 0; j < N; ++j)
            if (i != j && dist[i][j] < best) best = dist[i][j];
        lb += best;
    }
    return lb;
}

/* --------------------------------------------------------------------
 *  dfs_from_task()  —  branch-and-bound search seeded by Task
 *  Uses an explicit stack to avoid recursion (faster & ASAN-friendly). */
/* --------------------------------------------- dynamic DFS stack ---- */
#define INIT_CAP (1 << 15)                 /* 32 768 Nodes (~2.8 MiB)   */

static void dfs_from_task(const Task *t)
{
    size_t cap = INIT_CAP;                 /* current allocated slots   */
    Node  *stk = malloc(cap * sizeof(Node));
    size_t sp  = 0;
    long   expansions = 0;                 /* 64-bit to avoid wrap      */

    /* push root node copied from the Task --------------------------- */
    stk[sp++] = (Node){ t->city, t->depth, t->cost,
                        t->visitedMask, {0} };
    memcpy(stk[sp-1].path, t->path, t->depth * sizeof(int));

    while (sp) {
        Node n = stk[--sp];

        /* --- prune -------------------------------------------------- */
        if (n.cost >= best_cost ||
            lower_bound(n.cost, n.visitedMask) >= best_cost)
            continue;

        /* --- complete tour ----------------------------------------- */
        if (n.depth == N) {
            int tourCost = n.cost + dist[n.city][0];
            if (tourCost < best_cost) {
                best_cost = tourCost;
                memcpy(best_path, n.path, N * sizeof(int));
                best_path[N] = 0;
            }
            continue;
        }

        /* --- expand children --------------------------------------- */
        for (int next = 0; next < N; ++next) {
            if (n.visitedMask & (1 << next)) continue;
            int newCost = n.cost + dist[n.city][next];
            if (newCost >= best_cost) continue;

            /* ensure space for the push ----------------------------- */
            if (sp == cap) {
                cap *= 2;
                stk = realloc(stk, cap * sizeof(Node));
                if (!stk) { perror("realloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
            }
            Node c = n;
            c.city = next;
            c.cost = newCost;
            c.visitedMask |= 1 << next;
            c.path[c.depth] = next;
            c.depth++;
            stk[sp++] = c;
        }

        /* --- periodic global best sync ----------------------------- */
        if (++expansions % REDUCE_INTERVAL == 0) {
            int g;
            MPI_Allreduce(&best_cost, &g, 1, MPI_INT,
                          MPI_MIN, MPI_COMM_WORLD);
            best_cost = g;
        }
    }
    free(stk);                              /* tidy • avoids leaks      */
}


/* --------------------------------------------------------------------
 * wall_seconds()  —  portable high-res timer via MPI_Wtime()          */
static inline double wall_seconds(void) { return MPI_Wtime(); }

/* --------------------------------------------------------------------
 * master()  —  rank 0: keep a LIFO queue of Tasks and hand them out
 *              on demand until everyone reports no more work.         */
static void master(int world)
{
    Task queue[MAX_N];      /* at most N-1 seed tasks                 */
    int  qsz = 0;           /* stack size                              */

    /* ---- seed: city 0 → i  for i = 1..N-1 ------------------------ */
    for (int i = 1; i < N; ++i) {
        queue[qsz++] = (Task){
            .depth       = 1 + START_DEPTH,
            .cost        = dist[0][i],
            .city        = i,
            .visitedMask = (1 << 0) | (1 << i),
            .path        = {0}
        };
        queue[qsz - 1].path[0] = 0;
        queue[qsz - 1].path[1] = i;
    }

    int done = 0;           /* workers that received TAG_NOWORK       */
    MPI_Status st;

    while (done < world - 1) {
        /* wait for a work request --------------------------------- */
        MPI_Recv(NULL, 0, MPI_BYTE, MPI_ANY_SOURCE, TAG_REQ,
                 MPI_COMM_WORLD, &st);
        int dst = st.MPI_SOURCE;

        if (qsz) {          /* still have tasks → send one ---------- */
            MPI_Send(&queue[--qsz], sizeof(Task)/sizeof(int), MPI_INT,
                     dst, TAG_WORK, MPI_COMM_WORLD);
        } else {            /* queue empty → tell worker to exit ----- */
            MPI_Send(NULL, 0, MPI_BYTE, dst, TAG_NOWORK, MPI_COMM_WORLD);
            ++done;
        }
    }
}

/* --------------------------------------------------------------------
 * worker()  —  non-zero ranks: request tasks, process DFS, repeat
 *              until master replies TAG_NOWORK.                      */
static void worker(void)
{
    MPI_Status st;
    while (1) {
        MPI_Send(NULL, 0, MPI_BYTE, 0, TAG_REQ, MPI_COMM_WORLD);
        MPI_Probe(0, MPI_ANY_TAG, MPI_COMM_WORLD, &st);

        if (st.MPI_TAG == TAG_WORK) {
            Task t;
            MPI_Recv(&t, sizeof(Task)/sizeof(int), MPI_INT, 0,
                     TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            dfs_from_task(&t);
        } else {    /* TAG_NOWORK → nothing left -> exit loop ------- */
            MPI_Recv(NULL, 0, MPI_BYTE, 0, TAG_NOWORK,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            break;
        }
    }
}

/* --------------------------------------------------------------------
 * read_distance_file()  —  supports both full and triangular formats. */
static void read_distance_file(const char *fname)
{
    FILE *fp = fopen(fname, "r");
    if (!fp) { perror("open dist file"); MPI_Abort(MPI_COMM_WORLD, 1); }

    if (fscanf(fp, "%d", &N) != 1 || N > MAX_N) {
        fprintf(stderr, "bad N in file\n");
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    /* read up to MAX_N² ints into scratch array ------------------- */
    int nums[MAX_N * MAX_N];
    int cnt = 0;
    while (cnt < MAX_N * MAX_N &&
           fscanf(fp, "%d", &nums[cnt]) == 1) ++cnt;
    fclose(fp);

    const int needSquare = N * N;              /* full matrix ints   */
    const int needTri    = N * (N - 1) / 2;    /* upper-triangular   */

    if (cnt == needSquare) {                   /* square ---------- */
        for (int i = 0, k = 0; i < N; ++i)
            for (int j = 0; j < N; ++j)
                dist[i][j] = nums[k++];
    } else if (cnt == needTri) {               /* triangular ------ */
        int k = 0;
        for (int i = 1; i < N; ++i)
            for (int j = 0; j < i; ++j) {
                dist[i][j] = dist[j][i] = nums[k++];
            }
        for (int i = 0; i < N; ++i) dist[i][i] = 0;
    } else {                                   /* unsupported ----- */
        fprintf(stderr, "unsupported format (%d ints read)\n", cnt);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
}

/* ====================================================================
 *  main()  —  initialise MPI, load data, launch master/worker, gather.
 * ====================================================================*/
int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, world;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world);

    /* -------- validate CLI -------------------------------------- */
    if (argc != 2) {
        if (rank == 0)
            fprintf(stderr, "usage: %s <distance-file>\n", argv[0]);
        MPI_Finalize(); return 1;
    }

    /* -------- read & broadcast distance matrix ------------------ */
    if (rank == 0) read_distance_file(argv[1]);

    MPI_Bcast(&N, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(dist, MAX_N * MAX_N, MPI_INT, 0, MPI_COMM_WORLD);

    /* -------- branch-and-bound search --------------------------- */
    best_cost = INT_MAX;
    double t0 = wall_seconds();

    if (rank == 0) master(world);
    else           worker();

    /* -------- gather global optimum ----------------------------- */
    int global_best;
    MPI_Reduce(&best_cost, &global_best, 1, MPI_INT,
               MPI_MIN, 0, MPI_COMM_WORLD);

    double t1 = wall_seconds();

    if (rank == 0) {
        printf("Optimal tour cost: %d   time: %.3f s   ranks: %d\n",
               global_best, t1 - t0, world);
        /* Optional: print tour path here if desired */
    }

    MPI_Finalize();
    return 0;
}
