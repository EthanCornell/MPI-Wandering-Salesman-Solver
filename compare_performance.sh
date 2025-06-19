#!/bin/bash
#
# TSP Solver Performance Comparison Script
# Usage: ./compare_performance.sh [test_file] [max_ranks]
#

TESTFILE=${1:-"input/dist17"}
MAX_RANKS=${2:-8}
TIMEOUT=60

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to extract timing from output
extract_time() {
    grep -E "(time:|elapsed)" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# Function to extract cost from output
extract_cost() {
    grep -E "(cost:|best=)" | tail -1 | grep -oE '[0-9]+' | head -1
}

# Function to run and time a version
run_version() {
    local version=$1
    local ranks=$2
    local file=$3
    
    if [[ ! -f "./$version" ]]; then
        echo "MISSING"
        return 1
    fi
    
    local output
    output=$(timeout ${TIMEOUT}s mpirun -np $ranks ./$version $file 2>/dev/null)
    local exit_code=$?
    
    if [[ $exit_code -eq 124 ]]; then
        echo "TIMEOUT"
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        echo "ERROR"
        return 1
    fi
    
    local time_taken=$(echo "$output" | extract_time)
    local cost=$(echo "$output" | extract_cost)
    
    if [[ -z "$time_taken" ]]; then
        echo "NO_TIME"
        return 1
    fi
    
    echo "${time_taken}s (cost: ${cost})"
    return 0
}

# Function to print header
print_header() {
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}           TSP SOLVER PERFORMANCE COMPARISON${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "Test file: ${YELLOW}$TESTFILE${NC}"
    echo -e "Max ranks: ${YELLOW}$MAX_RANKS${NC}"
    echo -e "Timeout per test: ${YELLOW}${TIMEOUT}s${NC}"
    echo ""
}

# Function to print version comparison
compare_versions() {
    local ranks=$1
    echo -e "${GREEN}--- Comparison with $ranks ranks ---${NC}"
    
    printf "%-15s %-20s %-20s %-20s %-20s\n" "Version" "V1 (Basic)" "V2 (Enhanced)" "V3 (Work-steal)" "V4 (Ultra-opt)"
    printf "%-15s %-20s %-20s %-20s %-20s\n" "---------------" "--------------------" "--------------------" "--------------------" "--------------------"
    
    local result1=$(run_version "wsp-mpi" $ranks $TESTFILE)
    local result2=$(run_version "wsp-mpi_v2" $ranks $TESTFILE)
    local result3=$(run_version "wsp-mpi_v3" $ranks $TESTFILE)
    local result4=$(run_version "wsp-mpi_v4" $ranks $TESTFILE)
    
    printf "%-15s %-20s %-20s %-20s %-20s\n" "Time & Cost" "$result1" "$result2" "$result3" "$result4"
    echo ""
}

# Function to run scaling test
scaling_test() {
    echo -e "${GREEN}--- Scaling Test (V4 Ultra-optimized) ---${NC}"
    printf "%-10s %-15s %-10s\n" "Ranks" "Time" "Speedup"
    printf "%-10s %-15s %-10s\n" "----------" "---------------" "----------"
    
    local baseline_time=""
    
    for ranks in 1 2 4 8 16; do
        if [[ $ranks -gt $MAX_RANKS ]]; then
            break
        fi
        
        local result=$(run_version "wsp-mpi_v4" $ranks $TESTFILE)
        if [[ $result == *"s"* ]]; then
            local time=$(echo "$result" | grep -oE '[0-9]+\.[0-9]+')
            if [[ -z "$baseline_time" ]]; then
                baseline_time=$time
                printf "%-10s %-15s %-10s\n" "$ranks" "${time}s" "1.00x"
            else
                local speedup=$(echo "scale=2; $baseline_time / $time" | bc -l 2>/dev/null || echo "N/A")
                printf "%-10s %-15s %-10s\n" "$ranks" "${time}s" "${speedup}x"
            fi
        else
            printf "%-10s %-15s %-10s\n" "$ranks" "$result" "N/A"
        fi
    done
    echo ""
}

# Function to run multiple tests and compute statistics
benchmark_version() {
    local version=$1
    local ranks=$2
    local runs=5
    
    echo -e "${GREEN}--- Benchmarking $version with $ranks ranks ($runs runs) ---${NC}"
    
    local times=()
    local costs=()
    
    for run in $(seq 1 $runs); do
        echo -n "  Run $run: "
        local output
        output=$(timeout ${TIMEOUT}s mpirun -np $ranks ./$version $TESTFILE 2>/dev/null)
        local exit_code=$?
        
        if [[ $exit_code -eq 124 ]]; then
            echo "TIMEOUT"
            continue
        elif [[ $exit_code -ne 0 ]]; then
            echo "ERROR"
            continue
        fi
        
        local time_taken=$(echo "$output" | extract_time)
        local cost=$(echo "$output" | extract_cost)
        
        if [[ -n "$time_taken" && -n "$cost" ]]; then
            times+=($time_taken)
            costs+=($cost)
            echo "${time_taken}s (cost: $cost)"
        else
            echo "PARSE_ERROR"
        fi
    done
    
    if [[ ${#times[@]} -gt 0 ]]; then
        # Calculate statistics using awk
        local stats=$(printf '%s\n' "${times[@]}" | awk '
            {sum+=$1; sumsq+=$1*$1}
            END {
                mean=sum/NR
                std=sqrt(sumsq/NR - mean*mean)
                printf "%.3f %.3f", mean, std
            }
        ')
        local mean=$(echo $stats | cut -d' ' -f1)
        local std=$(echo $stats | cut -d' ' -f2)
        
        echo "  Statistics: mean=${mean}s, std=${std}s, runs=${#times[@]}/$runs"
        
        # Check cost consistency
        local unique_costs=$(printf '%s\n' "${costs[@]}" | sort -u | wc -l)
        if [[ $unique_costs -eq 1 ]]; then
            echo -e "  ${GREEN}✓ Consistent results (cost: ${costs[0]})${NC}"
        else
            echo -e "  ${RED}✗ Inconsistent results!${NC}"
        fi
    else
        echo -e "  ${RED}No successful runs!${NC}"
    fi
    echo ""
}

# Main execution
main() {
    print_header
    
    # Check if executables exist
    echo "Checking for executables..."
    for version in wsp-mpi wsp-mpi_v2 wsp-mpi_v3 wsp-mpi_v4; do
        if [[ -f "./$version" ]]; then
            echo -e "  ${GREEN}✓ $version${NC}"
        else
            echo -e "  ${RED}✗ $version (missing)${NC}"
        fi
    done
    echo ""
    
    # Quick verification
    echo -e "${GREEN}--- Quick Verification (4 ranks) ---${NC}"
    compare_versions 4
    
    # Scaling test
    if [[ $MAX_RANKS -gt 4 ]]; then
        scaling_test
    fi
    
    # Detailed benchmark of best version
    benchmark_version "wsp-mpi_v4" 8
    
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}Performance comparison complete!${NC}"
    echo -e "${BLUE}=======================================================${NC}"
}

# Run main function
main "$@"