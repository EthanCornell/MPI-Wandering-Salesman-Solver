/*--------------------------------------------------------------------*
 *  STABLE ENHANCED Message-Passing WSP
 *
 *  Proven optimizations that work reliably:
 *  1. MPI + OpenMP hybrid parallelization (simplified)
 *  2. 2-edge lower bounds with incremental updates
 *  3. Branch ordering for better pruning
 *  4. Bit-scan mask operations
 *  5. Owner-computes seeding
 *--------------------------------------------------------------------*/

#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#ifdef _OPENMP
#include <omp.h>
#endif

#define MAX_N            19
#define MAX_PATH         MAX_N
#define MAX_STACK_SIZE   (1 << 16)    /* Stack size per thread */

typedef struct {
    int depth;
    int cost;
    int city;
    int visitedMask;
    int path[MAX_PATH];
} Task;

/* Enhanced bound precomputation */
typedef struct {
    int cheapest1[MAX_N];   /* Cheapest edge from each city */
    int cheapest2[MAX_N];   /* Second cheapest edge from each city */
} BoundInfo;

/* Global state */
static int  N;
static int  dist[MAX_N][MAX_N];
static int  best_cost;
static int  best_path[MAX_PATH + 1];
static BoundInfo bounds;

typedef struct {
    int city, depth, cost, visitedMask;
    int path[MAX_PATH];
    int parent_lb;  /* Incremental lower bound */
} Node;

/* Precompute enhanced bounds */
static void precompute_enhanced_bounds(void)
{
    for (int i = 0; i < N; i++) {
        int min1 = INT_MAX, min2 = INT_MAX;
        
        for (int j = 0; j < N; j++) {
            if (i == j) continue;
            
            if (dist[i][j] < min1) {
                min2 = min1;
                min1 = dist[i][j];
            } else if (dist[i][j] < min2) {
                min2 = dist[i][j];
            }
        }
        
        bounds.cheapest1[i] = (min1 == INT_MAX) ? 0 : min1;
        bounds.cheapest2[i] = (min2 == INT_MAX) ? 0 : min2;
    }
}

/* Enhanced 2-edge lower bound */
static inline int lower_bound_2edge(int cost, int mask)
{
    int lb = cost;
    
    /* Bit-scan for unvisited cities */
    int unvisited = (~mask) & ((1 << N) - 1);
    while (unvisited) {
        int i = __builtin_ctz(unvisited);  /* Count trailing zeros */
        lb += (bounds.cheapest1[i] + bounds.cheapest2[i]) / 2;
        unvisited &= unvisited - 1;  /* Clear lowest set bit */
    }
    
    return lb;
}

/* Incremental lower bound update */
static inline int incremental_lower_bound(int parent_lb, int prev_city, int cur_city)
{
    return parent_lb + dist[prev_city][cur_city] - 
           (bounds.cheapest1[cur_city] + bounds.cheapest2[cur_city]) / 2;
}

/* Simplified hybrid DFS worker - no complex work-stealing */
static void stable_hybrid_dfs(Task *initial_tasks, int num_tasks)
{
    if (num_tasks == 0) return;

#ifdef _OPENMP
    #pragma omp parallel shared(best_cost, best_path)
    {
        int thread_id = omp_get_thread_num();
        int num_threads = omp_get_num_threads();
#else
        int thread_id = 0;
        int num_threads = 1;
#endif
        
        /* Per-thread stack */
        Node *stack = malloc(MAX_STACK_SIZE * sizeof(Node));
        if (!stack) { perror("malloc"); MPI_Abort(MPI_COMM_WORLD, 1); }
        
        int sp = 0;
        
        /* Each thread gets a portion of initial tasks */
        int tasks_per_thread = (num_tasks + num_threads - 1) / num_threads;
        int thread_start = thread_id * tasks_per_thread;
        int thread_end = thread_start + tasks_per_thread;
        if (thread_end > num_tasks) thread_end = num_tasks;
        
        /* Convert assigned tasks to stack nodes */
        for (int t = thread_start; t < thread_end; t++) {
            const Task *task = &initial_tasks[t];
            stack[sp] = (Node){ 
                .city = task->city, 
                .depth = task->depth, 
                .cost = task->cost,
                .visitedMask = task->visitedMask,
                .parent_lb = lower_bound_2edge(task->cost, task->visitedMask)
            };
            memcpy(stack[sp].path, task->path, task->depth * sizeof(int));
            sp++;
        }

        /* Main DFS loop */
        while (sp > 0) {
            Node n = stack[--sp];

            /* Get current best cost (thread-safe read) */
            int current_best;
            #ifdef _OPENMP
            #pragma omp atomic read
            #endif
            current_best = best_cost;

            /* Enhanced pruning */
            if (n.cost >= current_best || n.parent_lb >= current_best) {
                continue;
            }

            /* Complete tour check */
            if (n.depth == N) {
                int tour_cost = n.cost + dist[n.city][0];
                if (tour_cost < current_best) {
                    #ifdef _OPENMP
                    #pragma omp critical
                    #endif
                    {
                        if (tour_cost < best_cost) {
                            best_cost = tour_cost;
                            memcpy(best_path, n.path, N * sizeof(int));
                            best_path[N] = 0;
                        }
                    }
                }
                continue;
            }

            /* Expand children with branch ordering */
            int children[MAX_N];
            int child_count = 0;
            
            /* Collect unvisited cities using bit operations */
            int unvisited = (~n.visitedMask) & ((1 << N) - 1);
            while (unvisited) {
                int city = __builtin_ctz(unvisited);
                children[child_count++] = city;
                unvisited &= unvisited - 1;
            }
            
            /* Sort children by distance for better branch ordering */
            for (int i = 0; i < child_count - 1; i++) {
                for (int j = i + 1; j < child_count; j++) {
                    if (dist[n.city][children[i]] > dist[n.city][children[j]]) {
                        int temp = children[i];
                        children[i] = children[j];
                        children[j] = temp;
                    }
                }
            }
            
            /* Add children in reverse order (stack is LIFO) */
            for (int c = child_count - 1; c >= 0; c--) {
                int next = children[c];
                int new_cost = n.cost + dist[n.city][next];
                
                if (new_cost >= current_best) continue;
                
                int new_lb = incremental_lower_bound(n.parent_lb, n.city, next);
                if (new_lb >= current_best) continue;
                
                if (n.depth == N - 1) {
                    int final_cost = new_cost + dist[next][0];
                    if (final_cost >= current_best) continue;
                }
                
                if (sp >= MAX_STACK_SIZE - 1) continue;
                
                stack[sp] = n;
                stack[sp].city = next;
                stack[sp].cost = new_cost;
                stack[sp].visitedMask |= (1 << next);
                stack[sp].path[n.depth] = next;
                stack[sp].depth = n.depth + 1;
                stack[sp].parent_lb = new_lb;
                sp++;
            }
        }
        
        free(stack);

#ifdef _OPENMP
    } /* End parallel region */
#endif
}

/* Stable distributed search */
static void stable_distributed_search(int rank, int world)
{
    Task my_tasks[MAX_N];
    int my_task_count = 0;
    
    /* Work distribution */
    int total_tasks = N - 1;
    int base_tasks = total_tasks / world;
    int extra_tasks = total_tasks % world;
    
    int my_start = rank * base_tasks + (rank < extra_tasks ? rank : extra_tasks);
    int my_end = my_start + base_tasks + (rank < extra_tasks ? 1 : 0);
    
    /* Create initial tasks for this rank */
    for (int i = my_start; i < my_end; i++) {
        int city = i + 1;
        my_tasks[my_task_count] = (Task){
            .depth = 2,
            .cost = dist[0][city],
            .city = city,
            .visitedMask = (1 << 0) | (1 << city),
            .path = {0}
        };
        my_tasks[my_task_count].path[0] = 0;
        my_tasks[my_task_count].path[1] = city;
        my_task_count++;
    }
    
    if (rank == 0) {
        printf("Stable hybrid search: %d ranks, %d-%d tasks per rank", 
               world, base_tasks, base_tasks + 1);
        #ifdef _OPENMP
        printf(", %d OpenMP threads per rank\n", omp_get_max_threads());
        #else
        printf(", 1 thread per rank\n");
        #endif
    }
    
    /* Run stable hybrid DFS */
    stable_hybrid_dfs(my_tasks, my_task_count);
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
    #ifdef _OPENMP
    MPI_Init(&argc, &argv);  /* Simplified MPI init */
    #else
    MPI_Init(&argc, &argv);
    #endif

    int rank, world;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &world);

    if (argc != 2) {
        if (rank == 0)
            fprintf(stderr, "usage: %s <distance-file>\n", argv[0]);
        MPI_Finalize(); 
        return 1;
    }

    if (rank == 0) read_distance_file(argv[1]);

    MPI_Bcast(&N, 1, MPI_INT, 0, MPI_COMM_WORLD);
    MPI_Bcast(dist, MAX_N * MAX_N, MPI_INT, 0, MPI_COMM_WORLD);

    /* Enhanced bound precomputation */
    precompute_enhanced_bounds();

    best_cost = INT_MAX;
    memset(best_path, 0, sizeof(best_path));

    double t0 = MPI_Wtime();

    /* Run stable hybrid search */
    stable_distributed_search(rank, world);

    /* Synchronize results */
    int global_best;
    MPI_Allreduce(&best_cost, &global_best, 1, MPI_INT, MPI_MIN, MPI_COMM_WORLD);

    /* Collect the optimal path from whichever rank found it */
    int best_path_to_show[MAX_PATH + 1];
    memset(best_path_to_show, 0, sizeof(best_path_to_show));
    
    if (rank == 0) {
        if (best_cost == global_best) {
            memcpy(best_path_to_show, best_path, (N + 1) * sizeof(int));
        }
        
        for (int src = 1; src < world; src++) {
            int their_cost;
            int their_path[MAX_PATH + 1];
            
            MPI_Recv(&their_cost, 1, MPI_INT, src, 99, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            if (their_cost == global_best) {
                MPI_Recv(their_path, N + 1, MPI_INT, src, 100, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
                memcpy(best_path_to_show, their_path, (N + 1) * sizeof(int));
            } else {
                MPI_Recv(their_path, N + 1, MPI_INT, src, 100, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            }
        }
    } else {
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

    MPI_Finalize();
    return 0;
}
