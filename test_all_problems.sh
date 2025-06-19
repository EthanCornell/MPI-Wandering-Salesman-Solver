#!/bin/bash
#
# test_all_problems.sh - Comprehensive testing across problem sizes
#
# Tests TSP solver performance across different problem sizes (dist4-dist19)
#

set -euo pipefail

# Configuration
TIMEOUT=600  # 10 minutes max per test
DEFAULT_RANKS=8
PROGRAM="wsp-mpi_v4"  # Use best version by default

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Problem categories
SMALL_PROBLEMS=("dist4" "dist5" "dist6" "dist7" "dist8")
MEDIUM_PROBLEMS=("dist9" "dist10" "dist11" "dist12" "dist13" "dist14" "dist15")
LARGE_PROBLEMS=("dist16" "dist17" "dist18" "dist19")
ALT_PROBLEMS=("alt-dist15" "alt-dist16" "alt-dist17" "alt-dist18" "alt-dist19")

usage() {
    echo "Usage: $(basename $0) [category] [ranks] [program]"
    echo ""
    echo "Categories:"
    echo "  small    - Test dist4-dist8 (4-8 cities, very fast)"
    echo "  medium   - Test dist9-dist15 (9-15 cities, moderate)"  
    echo "  large    - Test dist16-dist19 (16-19 cities, challenging)"
    echo "  alt      - Test alternative problems (different distance matrices)"
    echo "  all      - Test all categories (default)"
    echo "  quick    - Test representative problems only"
    echo ""
    echo "Arguments:"
    echo "  ranks    - Number of MPI ranks (default: $DEFAULT_RANKS)"
    echo "  program  - Program version (default: $PROGRAM)"
    echo ""
    echo "Examples:"
    echo "  ./test_all_problems.sh small 4                    # Test small problems with 4 ranks"
    echo "  ./test_all_problems.sh medium 8 wsp-mpi_v3       # Test medium problems with v3"
    echo "  ./test_all_problems.sh quick                      # Quick test of representative problems"
    echo "  ./test_all_problems.sh all 16                     # Full test suite with 16 ranks"
}

# Function to run a single test
run_test() {
    local problem=$1
    local ranks=$2
    local program=$3
    local input_file="input/$problem"
    
    if [[ ! -f "$input_file" ]]; then
        echo -e "${YELLOW}SKIP${NC} (file not found)"
        return 1
    fi
    
    if [[ ! -f "./$program" ]]; then
        echo -e "${RED}ERROR${NC} (program not found)"
        return 1
    fi
    
    echo -n "Testing $problem (${ranks} ranks)... "
    
    local output
    output=$(timeout ${TIMEOUT}s mpirun -np $ranks ./$program $input_file 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 124 ]]; then
        echo -e "${RED}TIMEOUT${NC}"
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}ERROR${NC} (exit: $exit_code)"
        return 1
    fi
    
    # Extract results
    local time_taken=$(echo "$output" | grep -E "(time:|elapsed)" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
    local cost=$(echo "$output" | grep -E "(cost:|best=)" | tail -1 | grep -oE '[0-9]+' | head -1 || echo "")
    local cities=$(echo "$output" | grep -E "city|cities" | head -1 | grep -oE '[0-9]+' | head -1 || echo "")
    
    if [[ -n "$time_taken" && -n "$cost" ]]; then
        echo -e "${GREEN}OK${NC} (${time_taken}s, cost: $cost)"
        # Store results for summary
        echo "$problem,$cities,$time_taken,$cost,$ranks" >> "$results_file"
        return 0
    else
        echo -e "${YELLOW}PARSE_ERROR${NC}"
        return 1
    fi
}

# Function to test a category
test_category() {
    local category=$1
    local ranks=$2
    local program=$3
    local problems_array=$4
    
    echo -e "${BLUE}--- Testing $category problems ---${NC}"
    
    local success_count=0
    local total_count=0
    
    eval "local problems=(\"\${${problems_array}[@]}\")"
    
    for problem in "${problems[@]}"; do
        ((total_count++))
        if run_test "$problem" "$ranks" "$program"; then
            ((success_count++))
        fi
    done
    
    echo "Results: $success_count/$total_count successful"
    echo ""
}

# Function to generate performance summary
generate_summary() {
    local results_file=$1
    
    if [[ ! -f "$results_file" || ! -s "$results_file" ]]; then
        echo "No results to summarize."
        return
    fi
    
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${BLUE}           Performance Summary${NC}"
    echo -e "${BLUE}===============================================${NC}"
    
    # Sort by cities (problem size)
    sort -t',' -k2,2n "$results_file" > "${results_file}.sorted"
    
    printf "%-12s %-8s %-10s %-12s %-8s\n" "Problem" "Cities" "Time(s)" "Cost" "Ranks"
    printf "%-12s %-8s %-10s %-12s %-8s\n" "------------" "--------" "----------" "------------" "--------"
    
    while IFS=',' read -r problem cities time cost ranks; do
        printf "%-12s %-8s %-10s %-12s %-8s\n" "$problem" "$cities" "$time" "$cost" "$ranks"
    done < "${results_file}.sorted"
    
    echo ""
    
    # Calculate some basic statistics
    local total_tests=$(wc -l < "$results_file")
    local avg_time=$(awk -F',' '{sum+=$3} END {printf "%.3f", sum/NR}' "$results_file")
    local min_time=$(awk -F',' 'NR==1{min=$3} {if($3<min) min=$3} END {printf "%.3f", min}' "$results_file")
    local max_time=$(awk -F',' 'NR==1{max=$3} {if($3>max) max=$3} END {printf "%.3f", max}' "$results_file")
    
    echo "Statistics:"
    echo "  Tests completed: $total_tests"
    echo "  Average time: ${avg_time}s"
    echo "  Min time: ${min_time}s"
    echo "  Max time: ${max_time}s"
    
    # Performance scaling insight
    echo ""
    echo "Performance insights:"
    echo "  Problem sizes: $(awk -F',' '{print $2}' "$results_file" | sort -n | uniq | tr '\n' ' ')"
    echo "  Time complexity appears: $(awk -F',' 'BEGIN{prev_cities=0; prev_time=0} 
        {if(prev_cities>0) {
            ratio = $3/prev_time; 
            growth = $2/prev_cities;
            if(growth > 1) printf "%.1fx time for %.1fx cities; ", ratio, growth
        } 
        prev_cities=$2; prev_time=$3}' "${results_file}.sorted" | tail -1)"
    
    rm -f "${results_file}.sorted"
}

# Main function
main() {
    local category=${1:-"all"}
    local ranks=${2:-$DEFAULT_RANKS}
    local program=${3:-$PROGRAM}
    
    # Create results file
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local results_file="test_results_${timestamp}.csv"
    
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}           TSP Solver Comprehensive Testing${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo "Category: $category"
    echo "Ranks: $ranks"
    echo "Program: $program"
    echo "Timeout: ${TIMEOUT}s per test"
    echo "Results file: $results_file"
    echo ""
    
    # Check if program exists
    if [[ ! -f "./$program" ]]; then
        echo -e "${RED}Error: Program '$program' not found${NC}"
        echo "Available programs:"
        ls -1 ./wsp-mpi* 2>/dev/null || echo "  (no wsp-mpi programs found)"
        exit 1
    fi
    
    # Initialize results file
    echo "problem,cities,time,cost,ranks" > "$results_file"
    
    # Run tests based on category
    case $category in
        "small")
            test_category "small" "$ranks" "$program" "SMALL_PROBLEMS"
            ;;
        "medium")
            test_category "medium" "$ranks" "$program" "MEDIUM_PROBLEMS"
            ;;
        "large")
            test_category "large" "$ranks" "$program" "LARGE_PROBLEMS"
            ;;
        "alt")
            test_category "alternative" "$ranks" "$program" "ALT_PROBLEMS"
            ;;
        "quick")
            echo -e "${BLUE}--- Quick representative test ---${NC}"
            run_test "dist5" "$ranks" "$program"
            run_test "dist12" "$ranks" "$program"
            run_test "dist17" "$ranks" "$program"
            if [[ -f "input/alt-dist16" ]]; then
                run_test "alt-dist16" "$ranks" "$program"
            fi
            echo ""
            ;;
        "all")
            test_category "small" "$ranks" "$program" "SMALL_PROBLEMS"
            test_category "medium" "$ranks" "$program" "MEDIUM_PROBLEMS"
            test_category "large" "$ranks" "$program" "LARGE_PROBLEMS"
            if ls input/alt-dist* >/dev/null 2>&1; then
                test_category "alternative" "$ranks" "$program" "ALT_PROBLEMS"
            fi
            ;;
        *)
            echo -e "${RED}Unknown category: $category${NC}"
            usage
            exit 1
            ;;
    esac
    
    # Generate summary
    generate_summary "$results_file"
    
    echo ""
    echo -e "${GREEN}Testing complete! Results saved to: $results_file${NC}"
    echo -e "${BLUE}=======================================================${NC}"
}

# Check dependencies
if ! command -v timeout >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: 'timeout' command not found. Tests may run indefinitely.${NC}"
fi

# Run main function
main "$@"