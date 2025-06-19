#!/bin/bash
#
# compare_versions.sh - Test all TSP solver versions
#
# Usage: ./compare_versions.sh [input-file] [ranks]
#

INPUT_FILE=${1:-"input/dist15"}  # Changed from dist17 to dist15 for faster testing
RANKS=${2:-8}
TIMEOUT=1200

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Versions to test
VERSIONS=("wsp-mpi" "wsp-mpi_v2" "wsp-mpi_v3" "wsp-mpi_v4")

# Declare associative arrays for storing results
declare -A version_times
declare -A version_costs

# Function to extract results - improved to handle all output formats
extract_time() {
    # Look for patterns like "time: 0.368 s" or "elapsed time for proc X: Y"
    grep -oE "(time: [0-9]+\.[0-9]+|elapsed time[^:]*: [0-9]+\.[0-9]+)" | \
    grep -oE '[0-9]+\.[0-9]+' | head -1
}

extract_cost() {
    # Look for patterns like "Optimal tour cost: 317" or "best=317"
    grep -oE "(Optimal tour cost: [0-9]+|best=[0-9]+)" | \
    grep -oE '[0-9]+' | head -1
}

# Function to test a single version
test_version() {
    local version=$1
    local ranks=$2
    local input_file=$3
    
    if [[ ! -f "./$version" ]]; then
        echo "MISSING"
        return 1
    fi
    
    echo -n "Testing $version... "
    
    local output
    output=$(timeout ${TIMEOUT}s mpirun -np $ranks ./$version $input_file 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -eq 124 ]]; then
        echo "TIMEOUT"
        return 1
    elif [[ $exit_code -ne 0 ]]; then
        echo "ERROR (exit code: $exit_code)"
        # Debug: show some output
        echo "Debug output: $(echo "$output" | head -3)"
        return 1
    fi
    
    local time_taken=$(echo "$output" | extract_time)
    local cost=$(echo "$output" | extract_cost)
    
    if [[ -z "$time_taken" ]]; then
        echo "NO_TIME_FOUND"
        # Debug: show output to understand format
        echo "Debug output for time extraction: $(echo "$output" | grep -i time | head -2)"
        return 1
    fi
    
    if [[ -z "$cost" ]]; then
        echo "NO_COST_FOUND"
        # Debug: show output to understand format
        echo "Debug output for cost extraction: $(echo "$output" | grep -i cost | head -2)"
        return 1
    fi
    
    echo "✓ ${time_taken}s (cost: ${cost})"
    
    # Store results in associative arrays
    version_times[$version]=$time_taken
    version_costs[$version]=$cost
    
    return 0
}

# Function to run comparison using run_job.sh - improved argument handling
test_with_run_job() {
    local version=$1
    local ranks=$2
    local input_file=$3
    local nodes=1
    local ppn=$ranks
    
    # Adjust for larger rank counts
    if [[ $ranks -gt 24 ]]; then
        nodes=$((ranks / 24))
        ppn=24
        if [[ $((nodes * ppn)) -lt $ranks ]]; then
            nodes=$((nodes + 1))
        fi
    fi
    
    local outfile="test_${version}_${ranks}ranks.log"
    
    echo -n "Testing $version via run_job.sh... "
    
    # Check if run_job.sh exists and is executable
    if [[ ! -f "./run_job.sh" || ! -x "./run_job.sh" ]]; then
        echo "run_job.sh not found or not executable"
        return 1
    fi
    
    # Create a temporary modified run_job.sh that can handle different versions
    local temp_script="temp_run_job_${version}.sh"
    
    # Create a wrapper that modifies the program name
    cat > "$temp_script" << EOF
#!/bin/bash
# Temporary wrapper for testing $version
NODES=\$1
PROCESSORS_PER_NODE=\$2
STDOUT_FILE=\$3
INPUT_FILE=\$4
VERSION=\$5

# Calculate total processors
NP=\$((NODES * PROCESSORS_PER_NODE))

# Run the specified version
echo "Running: mpirun -np \$NP ./\$VERSION \$INPUT_FILE"
mpirun -np \$NP ./\$VERSION \$INPUT_FILE
EOF
    
    chmod +x "$temp_script"
    
    # Run with timeout and capture exit code
    if timeout 600s ./"$temp_script" $nodes $ppn $outfile $input_file $version > "$outfile" 2>&1; then
        if [[ -f "$outfile" ]]; then
            local time_taken=$(cat "$outfile" | extract_time)
            local cost=$(cat "$outfile" | extract_cost)
            
            if [[ -n "$time_taken" && -n "$cost" ]]; then
                echo "✓ ${time_taken}s (cost: ${cost})"
                rm -f "$outfile" "$temp_script"
                return 0
            else
                echo "FAILED (no results found)"
                # Debug: show some output
                echo "Debug output: $(cat "$outfile" | head -3)"
            fi
        else
            echo "FAILED (no output file)"
        fi
    else
        echo "FAILED (execution error)"
    fi
    
    rm -f "$outfile" "$temp_script"
    return 1
}

# Main comparison
main() {
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}           TSP Solver Version Comparison${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo "Input file: $INPUT_FILE"
    echo "MPI ranks: $RANKS"
    echo "Timeout: ${TIMEOUT}s per test"
    echo ""
    
    # Check available versions
    echo -e "${YELLOW}Available versions:${NC}"
    local available_count=0
    for version in "${VERSIONS[@]}"; do
        if [[ -f "./$version" ]]; then
            echo "  ✓ $version"
            ((available_count++))
        else
            echo "  ✗ $version (not built)"
        fi
    done
    echo ""
    
    if [[ $available_count -eq 0 ]]; then
        echo -e "${RED}No TSP solver executables found. Run 'make all' first.${NC}"
        exit 1
    fi
    
    # Direct mpirun tests
    echo -e "${GREEN}--- Direct mpirun Tests ---${NC}"
    local successful_tests=0
    local baseline_time=""
    
    for version in "${VERSIONS[@]}"; do
        if [[ -f "./$version" ]] && test_version $version $RANKS $INPUT_FILE; then
            ((successful_tests++))
            # Set baseline time from first successful test
            if [[ -z "$baseline_time" ]]; then
                baseline_time=${version_times[$version]}
            fi
        fi
    done
    echo ""
    
    # Show speedup comparison if we have results
    if [[ $successful_tests -gt 1 && -n "$baseline_time" ]]; then
        echo -e "${GREEN}--- Performance Comparison ---${NC}"
        printf "%-15s %-12s %-12s %-15s\n" "Version" "Time (s)" "Cost" "Speedup"
        printf "%-15s %-12s %-12s %-15s\n" "---------------" "------------" "------------" "---------------"
        
        for version in "${VERSIONS[@]}"; do
            if [[ -f "./$version" && -n "${version_times[$version]}" ]]; then
                local time_val=${version_times[$version]}
                local cost_val=${version_costs[$version]}
                local speedup="N/A"
                
                if command -v bc >/dev/null 2>&1 && [[ -n "$baseline_time" && -n "$time_val" ]]; then
                    speedup=$(echo "scale=2; $baseline_time / $time_val" | bc -l 2>/dev/null || echo "N/A")
                    if [[ "$speedup" != "N/A" ]]; then
                        speedup="${speedup}x"
                    fi
                fi
                
                printf "%-15s %-12s %-12s %-15s\n" "$version" "$time_val" "$cost_val" "$speedup"
            else
                printf "%-15s %-12s %-12s %-15s\n" "$version" "FAILED" "FAILED" "N/A"
            fi
        done
        echo ""
    fi
    
    # Test run_job.sh integration
    echo -e "${GREEN}--- Testing run_job.sh Integration ---${NC}"
    for version in "${VERSIONS[@]}"; do
        if [[ -f "./$version" ]]; then
            test_with_run_job $version $RANKS $INPUT_FILE
        fi
    done
    echo ""
    
    # Verify correctness
    echo -e "${GREEN}--- Correctness Verification ---${NC}"
    local costs=()
    for version in "${VERSIONS[@]}"; do
        if [[ -f "./$version" && -n "${version_costs[$version]}" ]]; then
            costs+=("${version_costs[$version]}")
        fi
    done
    
    if [[ ${#costs[@]} -gt 0 ]]; then
        local unique_costs=$(printf '%s\n' "${costs[@]}" | sort -u | wc -l)
        if [[ $unique_costs -eq 1 ]]; then
            echo -e "${GREEN}✓ All versions produce consistent results (cost: ${costs[0]})${NC}"
        else
            echo -e "${RED}✗ Inconsistent results detected!${NC}"
            echo "  Costs found: $(printf '%s ' "${costs[@]}")"
            echo ""
            echo "  Detailed breakdown:"
            for version in "${VERSIONS[@]}"; do
                if [[ -f "./$version" && -n "${version_costs[$version]}" ]]; then
                    echo "    $version: ${version_costs[$version]}"
                fi
            done
        fi
    else
        echo -e "${YELLOW}⚠ No successful runs for correctness verification${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}Comparison complete!${NC}"
    echo -e "${BLUE}=======================================================${NC}"
}

# Check dependencies
if ! command -v bc >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: 'bc' calculator not found. Speedup calculations will show 'N/A'${NC}"
fi

# Run main function
main "$@"