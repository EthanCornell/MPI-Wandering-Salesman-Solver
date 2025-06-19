/*--------------------------------------------------------------------*
 *  Message-Passing WSP - FULLY CORRECTED VERSION - Way1 
 *
 *  wsp-mpi.c  —  Branch-and-bound Travelling-Salesman solver
 *                using MPI across ≤ 18 cities.
 *--------------------------------------------------------------------*/

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

/* ---------- Tunables & limits -------------------------------------- */
#define MAX_N            19      /* Assignment never exceeds 18 cities   */
#define MAX_PATH         MAX_N   /* longest path prefix we store         */

/* ---------- MPI message tags  -------------------------------------- */
enum { TAG_REQ = 1, TAG_WORK, TAG_NOWORK, TAG_COST = 10, TAG_PATH = 11 };

/* ---------- Work unit ------------------------------------------------ */
typedef struct {
    int depth;           /* length of prefix -- includes city 0          */
    int cost;            /* cumulative cost of that prefix               */
    int city;            /* last city in the prefix                       */
    int visitedMask;     /* bitmask: 1 << i => city i already visited     */
    int path[MAX_PATH];  /* explicit prefix so we can reconstruct tours   */
} Task;

/* Helper function to send Task safely */
static void send_task(const Task *task, int dest) {
    MPI_Send(&task->depth, 1, MPI_INT, dest, TAG_WORK, MPI_COMM_WORLD);
    MPI_Send(&task->cost, 1, MPI_INT, dest, TAG_WORK, MPI_COMM_WORLD);
    MPI_Send(&task->city, 1, MPI_INT, dest, TAG_WORK, MPI_COMM_WORLD);
    MPI_Send(&task->visitedMask, 1, MPI_INT, dest, TAG_WORK, MPI_COMM_WORLD);
    MPI_Send(task->path, MAX_PATH, MPI_INT, dest, TAG_WORK, MPI_COMM_WORLD);
}

/* Helper function to receive Task safely */
static void recv_task(Task *task, int source) {
    MPI_Recv(&task->depth, 1, MPI_INT, source, TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    MPI_Recv(&task->cost, 1, MPI_INT, source, TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    MPI_Recv(&task->city, 1, MPI_INT, source, TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    MPI_Recv(&task->visitedMask, 1, MPI_INT, source, TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    MPI_Recv(task->path, MAX_PATH, MPI_INT, source, TAG_WORK, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
}

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
 *  lower_bound()  —  cheap admissible heuristic
 */
static inline int lower_bound(int cost, int mask)
{
    int lb = cost;
    for (int i = 0; i < N; ++i) {
        if (mask & (1 << i)) continue;          /* already visited */
        int best = INT_MAX;
        for (int j = 0; j < N; ++j)
            if (i != j && dist[i][j] < best) best = dist[i][j];
        if (best != INT_MAX) lb += best;
    }
    return lb;
}

/* --------------------------------------------------------------------
 *  dfs_from_task()  —  branch-and-bound search seeded by Task
 */
#define INIT_CAP (1 << 15)

static void dfs_from_task(const Task *t)
{
    size_t cap = INIT_CAP;
    Node  *stk = malloc(cap * sizeof(Node));
    if (!stk) { perror("malloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
    
    size_t sp = 0;

    /* push root node copied from the Task --------------------------- */
    stk[sp] = (Node){ t->city, t->depth, t->cost, t->visitedMask, {0} };
    memcpy(stk[sp].path, t->path, t->depth * sizeof(int));
    sp++;

    while (sp > 0) {
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
                best_path[N] = 0;  /* return to start */
            }
            continue;
        }

        /* --- expand children --------------------------------------- */
        for (int next = 0; next < N; ++next) {
            if (n.visitedMask & (1 << next)) continue;
            int newCost = n.cost + dist[n.city][next];
            if (newCost >= best_cost) continue;

            /* ensure space for the push ----------------------------- */
            if (sp >= cap) {
                cap *= 2;
                stk = realloc(stk, cap * sizeof(Node));
                if (!stk) { perror("realloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
            }
            
            /* Create child node */
            stk[sp] = n;  /* copy parent */
            stk[sp].city = next;
            stk[sp].cost = newCost;
            stk[sp].visitedMask |= (1 << next);
            stk[sp].path[n.depth] = next;  /* Add next city to path */
            stk[sp].depth = n.depth + 1;
            sp++;
        }
    }
    free(stk);
}

/* --------------------------------------------------------------------
 * master()  —  rank 0: distribute work and handle single-process case
 */
static void master(int world)
{
    Task queue[MAX_N];
    int  qsz = 0;

    /* ---- seed: city 0 → i  for i = 1..N-1 ------------------------ */
    for (int i = 1; i < N; ++i) {
        queue[qsz] = (Task){
            .depth       = 2,                    /* path: 0 → i */
            .cost        = dist[0][i],
            .city        = i,
            .visitedMask = (1 << 0) | (1 << i),
            .path        = {0}
        };
        queue[qsz].path[0] = 0;
        queue[qsz].path[1] = i;
        qsz++;
    }

    /* If single process, master does all the work */
    if (world == 1) {
        for (int i = 0; i < qsz; i++) {
            dfs_from_task(&queue[i]);
        }
        return;
    }

    /* Multi-process: distribute work */
    int done = 0;
    MPI_Status st;

    while (done < world - 1) {
        MPI_Recv(NULL, 0, MPI_BYTE, MPI_ANY_SOURCE, TAG_REQ, MPI_COMM_WORLD, &st);
        int dst = st.MPI_SOURCE;

        if (qsz > 0) {
            /* Send work using safe helper function */
            send_task(&queue[--qsz], dst);
        } else {
            /* No more work */
            MPI_Send(NULL, 0, MPI_BYTE, dst, TAG_NOWORK, MPI_COMM_WORLD);
            ++done;
        }
    }
}

/* --------------------------------------------------------------------
 * worker()  —  non-zero ranks: request tasks and process them
 */
static void worker(void)
{
    MPI_Status st;
    while (1) {
        MPI_Send(NULL, 0, MPI_BYTE, 0, TAG_REQ, MPI_COMM_WORLD);
        MPI_Probe(0, MPI_ANY_TAG, MPI_COMM_WORLD, &st);

        if (st.MPI_TAG == TAG_WORK) {
            Task t;
            recv_task(&t, 0);
            dfs_from_task(&t);
        } else {
            MPI_Recv(NULL, 0, MPI_BYTE, 0, TAG_NOWORK,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            break;
        }
    }
}

/* --------------------------------------------------------------------
 * read_distance_file()  —  supports both full and triangular formats
 */
static void read_distance_file(const char *fname)
{
    FILE *fp = fopen(fname, "r");
    if (!fp) { perror("open dist file"); MPI_Abort(MPI_COMM_WORLD, 1); }

    if (fscanf(fp, "%d", &N) != 1 || N > MAX_N || N <= 0) {
        fprintf(stderr, "Invalid N=%d in file (must be 1-%d)\n", N, MAX_N);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    /* Initialize distance matrix to 0 */
    memset(dist, 0, sizeof(dist));

    /* read distance data */
    int nums[MAX_N * MAX_N];
    int cnt = 0;
    while (cnt < MAX_N * MAX_N && fscanf(fp, "%d", &nums[cnt]) == 1) ++cnt;
    fclose(fp);

    const int needSquare = N * N;
    const int needTri    = N * (N - 1) / 2;

    if (cnt == needSquare) {
        /* square matrix */
        for (int i = 0, k = 0; i < N; ++i)
            for (int j = 0; j < N; ++j)
                dist[i][j] = nums[k++];
    } else if (cnt == needTri) {
        /* triangular matrix */
        int k = 0;
        for (int i = 1; i < N; ++i) {
            for (int j = 0; j < i; ++j) {
                dist[i][j] = dist[j][i] = nums[k++];
            }
        }
        /* diagonal is 0 (already set by memset) */
    } else {
        fprintf(stderr, "Unsupported format: %d ints read, need %d (square) or %d (triangular)\n", 
                cnt, needSquare, needTri);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    /* Debug: print first few distances */
    /*
    printf("Distance matrix preview:\n");
    for (int i = 0; i < (N < 5 ? N : 5); i++) {
        for (int j = 0; j < (N < 5 ? N : 5); j++) {
            printf("%3d ", dist[i][j]);
        }
        printf("\n");
    }
    */
}

/* ====================================================================
 *  main()
 * ====================================================================*/
int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, world;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world);

    /* validate CLI */
    if (argc != 2) {
        if (rank == 0)
            fprintf(stderr, "usage: %s <distance-file>\n", argv[0]);
        MPI_Finalize(); 
        return 1;
    }

    /* read & broadcast distance matrix */
    if (rank == 0) read_distance_file(argv[1]);

    MPI_Bcast(&N, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(dist, MAX_N * MAX_N, MPI_INT, 0, MPI_COMM_WORLD);

    /* initialize best solution */
    best_cost = INT_MAX;
    memset(best_path, 0, sizeof(best_path));

    double t0 = MPI_Wtime();

    /* run search */
    if (rank == 0) master(world);
    else           worker();

    /* gather global optimum AFTER all work is done */
    int global_best;
    int best_path_to_print[MAX_PATH + 1];
    
    if (world > 1) {
        MPI_Reduce(&best_cost, &global_best, 1, MPI_INT, MPI_MIN, 0, MPI_COMM_WORLD);
        
        /* Simple path collection using safe communication */
        if (rank == 0) {
            memcpy(best_path_to_print, best_path, (N + 1) * sizeof(int));
            
            /* Check if any worker has the optimal solution */
            for (int src = 1; src < world; src++) {
                int worker_cost;
                int worker_path[MAX_PATH + 1];
                
                MPI_Recv(&worker_cost, 1, MPI_INT, src, TAG_COST, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                MPI_Recv(worker_path, N + 1, MPI_INT, src, TAG_PATH, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                
                if (worker_cost == global_best) {
                    memcpy(best_path_to_print, worker_path, (N + 1) * sizeof(int));
                }
            }
        } else {
            /* Workers send their results */
            MPI_Send(&best_cost, 1, MPI_INT, 0, TAG_COST, MPI_COMM_WORLD);
            MPI_Send(best_path, N + 1, MPI_INT, 0, TAG_PATH, MPI_COMM_WORLD);
        }
    } else {
        global_best = best_cost;
        memcpy(best_path_to_print, best_path, (N + 1) * sizeof(int));
    }

    double t1 = MPI_Wtime();

    if (rank == 0) {
        printf("Optimal tour cost: %d   time: %.3f s   ranks: %d\n",
               global_best, t1 - t0, world);
        
        if (global_best < INT_MAX) {
            printf("Optimal path: ");
            for (int i = 0; i <= N; i++) {
                printf("%d ", best_path_to_print[i]);
            }
            printf("\n");
        } else {
            printf("No solution found!\n");
        }
    }

    MPI_Finalize();
    return 0;
}
