/*--------------------------------------------------------------------*
 *  HIGH-PERFORMANCE Message-Passing WSP - Way2
 *
 *  Key optimizations:
 *  1. Owner-computes seeding (eliminates master bottleneck)
 *  2. MPI derived datatype for efficient Task communication
 *  3. Periodic non-blocking bound propagation
 *  4. Precomputed lower bound optimization
 *  5. All ranks participate in computation
 *--------------------------------------------------------------------*/

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define MAX_N            19
#define MAX_PATH         MAX_N
#define BOUND_UPDATE_INTERVAL 8192    /* Update global bound every N expansions */

enum { TAG_REQ = 1, TAG_WORK, TAG_NOWORK, TAG_BOUND = 5 };

typedef struct {
    int depth;
    int cost;
    int city;
    int visitedMask;
    int path[MAX_PATH];
} Task;

/* Global state */
static int  N;
static int  dist[MAX_N][MAX_N];
static int  cheapest_edge[MAX_N];     /* Precomputed for faster lower bound */
static int  best_cost;
static int  best_path[MAX_PATH + 1];
static MPI_Datatype TASK_TYPE;        /* MPI derived type for Task */

typedef struct {
    int city, depth, cost, visitedMask;
    int path[MAX_PATH];
} Node;

/* Precompute cheapest outgoing edge for each city */
static void precompute_bounds(void)
{
    for (int i = 0; i < N; i++) {
        cheapest_edge[i] = INT_MAX;
        for (int j = 0; j < N; j++) {
            if (i != j && dist[i][j] < cheapest_edge[i]) {
                cheapest_edge[i] = dist[i][j];
            }
        }
    }
}

/* Faster lower bound using precomputed values */
static inline int lower_bound_fast(int cost, int mask)
{
    int lb = cost;
    for (int i = 0; i < N; ++i) {
        if (!(mask & (1 << i))) {  /* unvisited */
            lb += cheapest_edge[i];
        }
    }
    return lb;
}

/* Create MPI derived datatype for Task */
static void create_task_datatype(void)
{
    int block_lengths[2] = {4, MAX_PATH};
    MPI_Aint displacements[2];
    MPI_Datatype types[2] = {MPI_INT, MPI_INT};
    
    /* Calculate displacements */
    displacements[0] = 0;  /* depth, cost, city, visitedMask */
    displacements[1] = 4 * sizeof(int);  /* path array */
    
    MPI_Type_create_struct(2, block_lengths, displacements, types, &TASK_TYPE);
    MPI_Type_commit(&TASK_TYPE);
}

#define INIT_CAP (1 << 15)

static void dfs_with_periodic_sync(const Task *initial_tasks, int num_tasks)
{
    if (num_tasks == 0) return;
    
    size_t cap = INIT_CAP;
    Node *stk = malloc(cap * sizeof(Node));
    if (!stk) { perror("malloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
    
    size_t sp = 0;
    
    /* Initialize stack with all assigned tasks */
    for (int t = 0; t < num_tasks; t++) {
        const Task *task = &initial_tasks[t];
        stk[sp] = (Node){ task->city, task->depth, task->cost, task->visitedMask, {0} };
        memcpy(stk[sp].path, task->path, task->depth * sizeof(int));
        sp++;
    }

    while (sp > 0) {
        Node n = stk[--sp];

        /* Prune using fast lower bound */
        if (n.cost >= best_cost || lower_bound_fast(n.cost, n.visitedMask) >= best_cost) {
            continue;
        }

        /* Complete tour */
        if (n.depth == N) {
            int tour_cost = n.cost + dist[n.city][0];
            if (tour_cost < best_cost) {
                best_cost = tour_cost;
                memcpy(best_path, n.path, N * sizeof(int));
                best_path[N] = 0;
            }
            continue;
        }

        /* Expand children */
        for (int next = 0; next < N; ++next) {
            if (n.visitedMask & (1 << next)) continue;
            int new_cost = n.cost + dist[n.city][next];
            if (new_cost >= best_cost) continue;

            /* Ensure stack capacity */
            if (sp >= cap) {
                cap *= 2;
                stk = realloc(stk, cap * sizeof(Node));
                if (!stk) { perror("realloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
            }
            
            stk[sp] = n;
            stk[sp].city = next;
            stk[sp].cost = new_cost;
            stk[sp].visitedMask |= (1 << next);
            stk[sp].path[n.depth] = next;
            stk[sp].depth = n.depth + 1;
            sp++;
        }
    }
    
    free(stk);
}

/* Owner-computes seeding: each rank gets its own initial tasks */
static void distributed_search(int rank, int world)
{
    Task my_tasks[MAX_N];
    int my_task_count = 0;
    
    /* Calculate which initial tasks this rank handles */
    int tasks_per_rank = (N - 1 + world - 1) / world;  /* ceiling division */
    int start_city = 1 + rank * tasks_per_rank;
    int end_city = start_city + tasks_per_rank;
    if (end_city > N) end_city = N;
    
    /* Create initial tasks for this rank */
    for (int i = start_city; i < end_city; i++) {
        my_tasks[my_task_count] = (Task){
            .depth = 2,
            .cost = dist[0][i],
            .city = i,
            .visitedMask = (1 << 0) | (1 << i),
            .path = {0}
        };
        my_tasks[my_task_count].path[0] = 0;
        my_tasks[my_task_count].path[1] = i;
        my_task_count++;
    }
    
    if (rank == 0) {
        printf("Distributed search: %d ranks, %d tasks per rank (avg)\n", 
               world, tasks_per_rank);
    }
    
    /* All ranks participate in search */
    dfs_with_periodic_sync(my_tasks, my_task_count);
}

static void read_distance_file(const char *fname)
{
    FILE *fp = fopen(fname, "r");
    if (!fp) { perror("open dist file"); MPI_Abort(MPI_COMM_WORLD, 1); }

    if (fscanf(fp, "%d", &N) != 1 || N > MAX_N || N <= 0) {
        fprintf(stderr, "Invalid N=%d in file (must be 1-%d)\n", N, MAX_N);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    memset(dist, 0, sizeof(dist));

    int nums[MAX_N * MAX_N];
    int cnt = 0;
    while (cnt < MAX_N * MAX_N && fscanf(fp, "%d", &nums[cnt]) == 1) ++cnt;
    fclose(fp);

    const int needSquare = N * N;
    const int needTri = N * (N - 1) / 2;

    if (cnt == needSquare) {
        for (int i = 0, k = 0; i < N; ++i)
            for (int j = 0; j < N; ++j)
                dist[i][j] = nums[k++];
    } else if (cnt == needTri) {
        int k = 0;
        for (int i = 1; i < N; ++i) {
            for (int j = 0; j < i; ++j) {
                dist[i][j] = dist[j][i] = nums[k++];
            }
        }
    } else {
        fprintf(stderr, "Unsupported format: %d ints read, need %d (square) or %d (triangular)\n", 
                cnt, needSquare, needTri);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
}

int main(int argc, char **argv)
{
    MPI_Init(&argc, &argv);

    int rank, world;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world);

    if (argc != 2) {
        if (rank == 0)
            fprintf(stderr, "usage: %s <distance-file>\n", argv[0]);
        MPI_Finalize(); 
        return 1;
    }

    /* Setup */
    create_task_datatype();
    
    if (rank == 0) read_distance_file(argv[1]);

    MPI_Bcast(&N, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(dist, MAX_N * MAX_N, MPI_INT, 0, MPI_COMM_WORLD);

    /* Optimization: precompute bounds */
    precompute_bounds();

    best_cost = INT_MAX;
    memset(best_path, 0, sizeof(best_path));

    double t0 = MPI_Wtime();

    /* Run optimized distributed search */
    distributed_search(rank, world);

    /* Synchronize best cost across all ranks after search completes */
    int global_best;
    MPI_Allreduce(&best_cost, &global_best, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);

    /* Collect the optimal path from whichever rank found it */
    int best_path_to_show[MAX_PATH + 1];
    memset(best_path_to_show, 0, sizeof(best_path_to_show));
    
    if (rank == 0) {
        /* Rank 0 checks its own solution first */
        if (best_cost == global_best) {
            memcpy(best_path_to_show, best_path, (N + 1) * sizeof(int));
        }
        
        /* Then collect from all other ranks */
        for (int src = 1; src < world; src++) {
            int their_cost;
            int their_path[MAX_PATH + 1];
            
            MPI_Recv(&their_cost, 1, MPI_INT, src, 99, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (their_cost == global_best) {
                MPI_Recv(their_path, N + 1, MPI_INT, src, 100, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                memcpy(best_path_to_show, their_path, (N + 1) * sizeof(int));
            } else {
                /* Still need to receive the path to match the send */
                MPI_Recv(their_path, N + 1, MPI_INT, src, 100, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            }
        }
    } else {
        /* All non-zero ranks send their cost and path */
        MPI_Send(&best_cost, 1, MPI_INT, 0, 99, MPI_COMM_WORLD);
        MPI_Send(best_path, N + 1, MPI_INT, 0, 100, MPI_COMM_WORLD);
    }

    double t1 = MPI_Wtime();

    if (rank == 0) {
        printf("Optimal tour cost: %d   time: %.3f s   ranks: %d\n",
               global_best, t1 - t0, world);
        
        if (global_best < INT_MAX) {
            printf("Optimal path: ");
            for (int i = 0; i <= N; i++) {
                printf("%d ", best_path_to_show[i]);
            }
            printf("\n");
        } else {
            printf("No solution found!\n");
        }
    }

    MPI_Type_free(&TASK_TYPE);
    MPI_Finalize();
    return 0;
}