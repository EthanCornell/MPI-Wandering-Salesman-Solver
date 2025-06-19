CC      = mpicc
CFLAGS  = -O3 -std=c11 -Wall -Wextra -march=native
LDFLAGS =

# OpenMP support (comment out if not available)
OPENMP_FLAGS = -fopenmp

# Default target builds all versions
all: wsp-mpi wsp-mpi_v2 wsp-mpi_v3 wsp-mpi_v4

# Individual targets
wsp-mpi: wsp-mpi.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

wsp-mpi_v2: wsp-mpi_v2.c
	$(CC) $(CFLAGS) $(OPENMP_FLAGS) -o $@ $< $(LDFLAGS)

wsp-mpi_v3: wsp-mpi_v3.c
	$(CC) $(CFLAGS) $(OPENMP_FLAGS) -o $@ $< $(LDFLAGS)

wsp-mpi_v4: wsp-mpi_v4.c
	$(CC) $(CFLAGS) $(OPENMP_FLAGS) -o $@ $< $(LDFLAGS)

# Test targets for different problem sizes
test-small: all
	@echo "=== Testing on small problems (dist4-dist8) ==="
	@$(MAKE) run-comparison TESTFILE=input/dist5 RANKS=4

test-medium: all
	@echo "=== Testing on medium problems (dist9-dist15) ==="
	@$(MAKE) run-comparison TESTFILE=input/dist12 RANKS=8

test-large: all
	@echo "=== Testing on large problems (dist16-dist19) ==="
	@$(MAKE) run-comparison TESTFILE=input/dist17 RANKS=8

test-comprehensive: all
	@echo "=== Comprehensive testing across all problem sizes ==="
	@./test_all_problems.sh quick 8

# Performance comparison
compare: all
	@echo "======================================================="
	@echo "           TSP SOLVER PERFORMANCE COMPARISON"
	@echo "======================================================="
	@$(MAKE) test-small
	@echo ""
	@$(MAKE) test-medium
	@echo ""
	@$(MAKE) test-large
	@echo ""
	@$(MAKE) test-comprehensive

# Comprehensive problem size testing
test-all-sizes: all
	@echo "======================================================="
	@echo "           COMPREHENSIVE PROBLEM SIZE TESTING"
	@echo "======================================================="
	@./test_all_problems.sh all 8

# Individual performance tests
TESTFILE ?= input/dist15
RANKS ?= 8

run-comparison:
	@echo "Testing with $(RANKS) ranks on $(TESTFILE)"
	@echo "-------------------------------------------------------"
	@echo "V1 (Basic): "
	@timeout 30s mpirun -np $(RANKS) ./wsp-mpi $(TESTFILE) 2>/dev/null || echo "TIMEOUT/ERROR"
	@echo ""
	@echo "V2 (Enhanced): "
	@timeout 30s mpirun -np $(RANKS) ./wsp-mpi_v2 $(TESTFILE) 2>/dev/null || echo "TIMEOUT/ERROR"
	@echo ""
	@echo "V3 (Work-stealing): "
	@timeout 30s mpirun -np $(RANKS) ./wsp-mpi_v3 $(TESTFILE) 2>/dev/null || echo "TIMEOUT/ERROR"
	@echo ""
	@echo "V4 (Ultra-optimized): "
	@timeout 30s mpirun -np $(RANKS) ./wsp-mpi_v4 $(TESTFILE) 2>/dev/null || echo "TIMEOUT/ERROR"
	@echo "-------------------------------------------------------"

# Scaling tests
scaling-test: wsp-mpi_v4
	@echo "======================================================="
	@echo "           SCALING PERFORMANCE TEST"
	@echo "======================================================="
	@for ranks in 1 2 4 8 16; do \
		echo "Testing with $$ranks ranks:"; \
		timeout 60s mpirun -np $$ranks ./wsp-mpi_v4 $(TESTFILE) 2>/dev/null || echo "TIMEOUT"; \
		echo ""; \
	done

# Detailed benchmarking with multiple runs
benchmark: wsp-mpi_v4
	@echo "======================================================="
	@echo "           DETAILED BENCHMARK (5 runs each)"
	@echo "======================================================="
	@for ranks in 2 4 8; do \
		echo "Benchmarking $$ranks ranks (5 runs):"; \
		for run in 1 2 3 4 5; do \
			echo -n "  Run $$run: "; \
			timeout 60s mpirun -np $$ranks ./wsp-mpi_v4 $(TESTFILE) 2>/dev/null | grep "time:" | tail -1 || echo "FAILED"; \
		done; \
		echo ""; \
	done

# Quick verification that all versions produce same result
verify: all
	@echo "======================================================="
	@echo "           CORRECTNESS VERIFICATION"
	@echo "======================================================="
	@echo "All versions should produce the same optimal cost:"
	@echo -n "V1: "; timeout 30s mpirun -np 4 ./wsp-mpi input/dist15 2>/dev/null | grep "cost:" | tail -1 || echo "FAILED"
	@echo -n "V2: "; timeout 30s mpirun -np 4 ./wsp-mpi_v2 input/dist15 2>/dev/null | grep "cost:" | tail -1 || echo "FAILED"
	@echo -n "V3: "; timeout 30s mpirun -np 4 ./wsp-mpi_v3 input/dist15 2>/dev/null | grep "cost:" | tail -1 || echo "FAILED"
	@echo -n "V4: "; timeout 30s mpirun -np 4 ./wsp-mpi_v4 input/dist15 2>/dev/null | grep "cost:" | tail -1 || echo "FAILED"

# Memory and debugging builds
debug: CFLAGS += -g -O0 -DDEBUG
debug: all

profile: CFLAGS += -pg
profile: all

# Generate performance report
report: wsp-mpi_v4
	@echo "=======================================================" > performance_report.txt
	@echo "           TSP SOLVER PERFORMANCE REPORT" >> performance_report.txt
	@echo "           Generated: $$(date)" >> performance_report.txt
	@echo "=======================================================" >> performance_report.txt
	@echo "" >> performance_report.txt
	@echo "System Information:" >> performance_report.txt
	@echo "  CPU: $$(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)" >> performance_report.txt
	@echo "  Cores: $$(nproc)" >> performance_report.txt
	@echo "  MPI: $$(mpirun --version | head -1)" >> performance_report.txt
	@echo "  Compiler: $$($(CC) --version | head -1)" >> performance_report.txt
	@echo "" >> performance_report.txt
	@$(MAKE) scaling-test >> performance_report.txt 2>&1
	@echo "" >> performance_report.txt
	@$(MAKE) benchmark >> performance_report.txt 2>&1
	@echo "Performance report saved to performance_report.txt"

# Help target
help:
	@echo "Available targets:"
	@echo "  all              - Build all versions (v1-v4)"
	@echo "  compare          - Run performance comparison on all problem sizes"
	@echo "  test-small       - Test on small problems (dist4-dist8)"
	@echo "  test-medium      - Test on medium problems (dist9-dist15)"
	@echo "  test-large       - Test on large problems (dist16-dist19)"
	@echo "  test-comprehensive - Quick test across problem sizes"
	@echo "  test-all-sizes   - Comprehensive testing (all problems dist4-dist19)"
	@echo "  scaling-test     - Test scaling from 1-16 ranks"
	@echo "  benchmark        - Detailed benchmarking with multiple runs"
	@echo "  verify           - Verify all versions produce same result"
	@echo "  report           - Generate comprehensive performance report"
	@echo "  debug            - Build debug versions"
	@echo "  profile          - Build profiling versions"
	@echo "  clean            - Remove all executables"
	@echo ""
	@echo "Variables:"
	@echo "  TESTFILE         - Input file (default: input/dist15)"
	@echo "  RANKS            - Number of MPI ranks (default: 8)"
	@echo ""
	@echo "Examples:"
	@echo "  make compare                              # Full comparison"
	@echo "  make test-all-sizes                       # Test all problem sizes"
	@echo "  make scaling-test TESTFILE=input/dist12   # Scaling test on dist12"
	@echo "  make run-comparison RANKS=4 TESTFILE=input/dist6  # Custom test"
	@echo ""
	@echo "Problem size recommendations:"
	@echo "  Small (4-8 cities):   dist4, dist5, dist6 - very fast testing"
	@echo "  Medium (9-15 cities): dist9, dist12, dist15 - moderate complexity"
	@echo "  Large (16-19 cities): dist17, dist18, dist19 - challenging problems"

# Clean target
clean:
	rm -f wsp-mpi wsp-mpi_v2 wsp-mpi_v3 wsp-mpi_v4
	rm -f performance_report.txt
	rm -f *.o *.out gmon.out

.PHONY: all test-small test-medium test-large compare run-comparison scaling-test benchmark verify debug profile report help clean