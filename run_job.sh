#!/bin/bash
#
# run_job.sh - Smart wrapper for TSP solver with version selection
#
# Usage: ./run_job.sh <nodes> <ppn> <stdout-file> [input-file] [version]
#
# If qsub exists → submits PBS job with requested resources
# Else → runs mpirun locally and writes output to file
#

set -euo pipefail

# Configuration
MAX_NODES=4
MAX_PPN=24
WALLTIME_MINUTES=30

# Available versions
AVAILABLE_VERSIONS=("wsp-mpi" "wsp-mpi_v2" "wsp-mpi_v3" "wsp-mpi_v4")

# Error codes
E_BADARGS=65

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print usage
usage() {
    echo "Usage: $(basename $0) <nodes> <ppn> <stdout-file> [input-file] [version]"
    echo ""
    echo "Arguments:"
    echo "  nodes        Number of nodes (1-${MAX_NODES})"
    echo "  ppn          Processors per node (1-${MAX_PPN})"
    echo "  stdout-file  Output file for results"
    echo "  input-file   Optional: TSP input file (default: input/dist17)"
    echo "               Available: dist4-dist19, alt-dist15-alt-dist20"
    echo "  version      Optional: Program version (default: auto-detect best)"
    echo ""
    echo "Available versions:"
    for version in "${AVAILABLE_VERSIONS[@]}"; do
        if [[ -f "./$version" ]]; then
            echo "  ✓ $version"
        else
            echo "  ✗ $version (not built)"
        fi
    done
    echo ""
    echo "Examples:"
    echo "  ./run_job.sh 2 12 tsp.2x12.log                              # Auto-select best version"
    echo "  ./run_job.sh 1 8 results.log input/dist15                   # 8 ranks, custom input"
    echo "  ./run_job.sh 4 24 big.log input/dist19 wsp-mpi_v4          # Force specific version"
    echo "  ./run_job.sh 1 1 serial.log input/dist4 wsp-mpi            # Serial run, small problem"
    echo "  ./run_job.sh 2 8 medium.log input/alt-dist16               # Alternative distance matrix"
    echo ""
    echo "Behavior:"
    echo "  • If 'qsub' command exists → submits PBS job"
    echo "  • Otherwise → runs locally with mpirun"
    echo "  • Version auto-detection prefers: v4 > v3 > v2 > basic"
}

# Function to select best available version
select_program_version() {
    local requested_version=${1:-""}
    
    # If specific version requested, validate it
    if [[ -n "$requested_version" ]]; then
        if [[ -f "./$requested_version" ]]; then
            echo "$requested_version"
            return 0
        else
            echo -e "${RED}Error: Requested version '${requested_version}' not found${NC}" >&2
            return 1
        fi
    fi
    
    # Auto-detect best available version (prefer v4 > v3 > v2 > basic)
    for version in wsp-mpi_v4 wsp-mpi_v3 wsp-mpi_v2 wsp-mpi; do
        if [[ -f "./$version" ]]; then
            echo "$version"
            return 0
        fi
    done
    
    echo -e "${RED}Error: No TSP solver executable found. Run 'make' first.${NC}" >&2
    return 1
}

# Function to validate arguments
validate_args() {
    local nodes=$1
    local ppn=$2
    local outfile=$3
    
    # Check if arguments are numbers
    if ! [[ "$nodes" =~ ^[0-9]+$ ]] || ! [[ "$ppn" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: nodes and ppn must be positive integers${NC}" >&2
        return $E_BADARGS
    fi
    
    # Validate ranges
    if [[ $nodes -le 0 || $nodes -gt $MAX_NODES ]]; then
        echo -e "${RED}Error: nodes must be 1-${MAX_NODES}, got ${nodes}${NC}" >&2
        return $E_BADARGS
    fi
    
    if [[ $ppn -le 0 || $ppn -gt $MAX_PPN ]]; then
        echo -e "${RED}Error: ppn must be 1-${MAX_PPN}, got ${ppn}${NC}" >&2
        return $E_BADARGS
    fi
    
    # Check if output directory is writable
    local outdir=$(dirname "$outfile")
    if [[ ! -w "$outdir" ]]; then
        echo -e "${RED}Error: Cannot write to directory ${outdir}${NC}" >&2
        return $E_BADARGS
    fi
    
    return 0
}

# Function to generate PBS script
generate_pbs_script() {
    local nodes=$1
    local ppn=$2
    local outfile=$3
    local inputfile=$4
    local program=$5
    local total_procs=$((nodes * ppn))
    
    local pbs_script="${outfile%.log}.pbs"
    
    cat > "$pbs_script" << EOF
#!/bin/bash
#PBS -N tsp_solver
#PBS -l walltime=0:${WALLTIME_MINUTES}:00
#PBS -l nodes=${nodes}:ppn=${ppn}
#PBS -j oe
#PBS -o ${outfile}

# Change to submission directory
cd \$PBS_O_WORKDIR

# Print job information
echo "==============================================="
echo "TSP Solver PBS Job"
echo "==============================================="
echo "Job ID: \$PBS_JOBID"
echo "Job Name: \$PBS_JOBNAME"
echo "Nodes: ${nodes}"
echo "Processors per node: ${ppn}"
echo "Total processors: ${total_procs}"
echo "Program version: ${program}"
echo "Input file: ${inputfile}"
echo "Started: \$(date)"
echo "Host: \$(hostname)"
echo "Working directory: \$PWD"
echo "==============================================="
echo ""

# Show available nodes
echo "Available nodes:"
cat \$PBS_NODEFILE | sort | uniq -c
echo ""

# Calculate host list for mpirun
echo "Building host list for MPI..."
HOSTS=\$(cat \$PBS_NODEFILE | sort | uniq | awk -v ppn=${ppn} '{for(i=0; i<ppn; i++) { print \$0; }}' | paste -d, -s)
echo "Host list: \$HOSTS"
echo ""

# Set MPI options for cluster performance
export OMPI_MCA_btl_tcp_if_include=em1,eth0
export OMPI_MCA_plm_rsh_agent=ssh

# Run the TSP solver
echo "Executing: mpirun -host \$HOSTS -np ${total_procs} ./${program} ${inputfile}"
echo ""

# Time the execution
START_TIME=\$(date +%s.%N)

mpirun --mca btl_tcp_if_include em1,eth0 \\
       --mca plm_rsh_agent ssh \\
       -host "\$HOSTS" \\
       -np ${total_procs} \\
       ./${program} ${inputfile}

EXIT_CODE=\$?
END_TIME=\$(date +%s.%N)
WALL_TIME=\$(echo "\$END_TIME - \$START_TIME" | bc -l)

echo ""
echo "==============================================="
echo "Job Statistics"
echo "==============================================="
echo "Wall time: \${WALL_TIME} seconds"
echo "Exit code: \$EXIT_CODE"
echo "Completed: \$(date)"
echo "==============================================="
EOF

    echo "$pbs_script"
}

# Function to run locally
run_local() {
    local nodes=$1
    local ppn=$2
    local outfile=$3
    local inputfile=$4
    local program=$5
    local total_procs=$((nodes * ppn))
    
    echo -e "${BLUE}Running locally with ${total_procs} MPI ranks${NC}"
    echo -e "${YELLOW}Program: ${program}${NC}"
    echo -e "${YELLOW}Output will be written to: ${outfile}${NC}"
    
    # Initialize variables outside the subshell
    local EXIT_CODE=0
    local START_TIME
    local END_TIME
    local WALL_TIME
    local available_cores=$(nproc)
    
    # Function to write header
    write_header() {
        echo "==============================================="
        echo "TSP Solver Local Run"
        echo "==============================================="
        echo "Command: mpirun -np ${total_procs} ./${program} ${inputfile}"
        echo "Requested: ${nodes} nodes × ${ppn} ppn = ${total_procs} ranks"
        echo "Program version: ${program}"
        echo "Input file: ${inputfile}"
        echo "Started: $(date)"
        echo "Host: $(hostname)"
        echo "Working directory: $PWD"
        echo "==============================================="
        echo ""
        echo "System cores: ${available_cores}"
    }
    
    # Function to write footer
    write_footer() {
        echo ""
        echo "==============================================="
        echo "Local Run Statistics"
        echo "==============================================="
        echo "Wall time: ${WALL_TIME} seconds"
        echo "Exit code: $EXIT_CODE"
        echo "Completed: $(date)"
        echo "==============================================="
    }
    
    # Write to file and capture output
    exec 3>&1 4>&2  # Save stdout and stderr
    exec 1> >(tee "$outfile") 2>&1  # Redirect to tee
    
    write_header
    
    if [[ $total_procs -gt $available_cores ]]; then
        echo "Warning: Requesting ${total_procs} ranks but only ${available_cores} cores available"
        echo "Using --oversubscribe flag for time-sharing"
        echo ""
        echo "Executing: mpirun --oversubscribe -np ${total_procs} ./${program} ${inputfile}"
        echo ""
        
        # Time the execution
        START_TIME=$(date +%s.%N)
        mpirun --oversubscribe -np $total_procs ./$program $inputfile
        EXIT_CODE=$?
        END_TIME=$(date +%s.%N)
    else
        echo "Executing: mpirun -np ${total_procs} ./${program} ${inputfile}"
        echo ""
        
        # Time the execution
        START_TIME=$(date +%s.%N)
        mpirun -np $total_procs ./$program $inputfile
        EXIT_CODE=$?
        END_TIME=$(date +%s.%N)
    fi
    
    WALL_TIME=$(echo "$END_TIME - $START_TIME" | bc -l 2>/dev/null || echo "N/A")
    
    write_footer
    
    # Restore stdout and stderr
    exec 1>&3 2>&4 3>&- 4>&-
    
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo -e "${GREEN}✓ Local run completed successfully. Results saved to: ${outfile}${NC}"
    else
        echo -e "${RED}✗ Local run failed with exit code: $EXIT_CODE${NC}"
    fi
    
    return $EXIT_CODE
}

# Function to submit PBS job
submit_pbs() {
    local nodes=$1
    local ppn=$2
    local outfile=$3
    local inputfile=$4
    local program=$5
    
    echo -e "${BLUE}Submitting PBS job with ${nodes} nodes × ${ppn} ppn${NC}"
    
    local pbs_script=$(generate_pbs_script $nodes $ppn $outfile $inputfile $program)
    
    echo -e "${YELLOW}Generated PBS script: ${pbs_script}${NC}"
    
    # Submit the job
    local job_id
    if job_id=$(qsub "$pbs_script" 2>&1); then
        echo -e "${GREEN}✓ Job submitted successfully${NC}"
        echo -e "${GREEN}Job ID: ${job_id}${NC}"
        echo -e "${YELLOW}Output will be written to: ${outfile}${NC}"
        echo ""
        echo "Monitor job status with:"
        echo "  qstat -u \$USER"
        echo "  qstat -f ${job_id}"
        echo ""
        echo "Cancel job if needed:"
        echo "  qdel ${job_id}"
    else
        echo -e "${RED}✗ Failed to submit job: ${job_id}${NC}" >&2
        echo -e "${YELLOW}Falling back to local execution...${NC}"
        run_local $nodes $ppn $outfile $inputfile $program
    fi
}

# Function to detect environment
detect_environment() {
    if command -v qsub >/dev/null 2>&1; then
        echo "pbs"
    else
        echo "local"
    fi
}

# Main function
main() {
    # Check argument count
    if [[ $# -lt 3 || $# -gt 5 ]]; then
        echo -e "${RED}Error: Wrong number of arguments${NC}" >&2
        usage
        exit $E_BADARGS
    fi
    
    local nodes=$1
    local ppn=$2
    local outfile=$3
    local inputfile=${4:-"input/dist17"}
    local requested_version=${5:-""}
    
    # Validate arguments
    if ! validate_args $nodes $ppn $outfile; then
        usage
        exit $E_BADARGS
    fi
    
    # Check if input file exists
    if [[ ! -f "$inputfile" ]]; then
        echo -e "${RED}Error: Input file '${inputfile}' not found${NC}" >&2
        echo "Available input files:"
        echo "  Standard problems (dist4-dist19):"
        ls -1 input/dist* 2>/dev/null | grep -E "dist[0-9]+$" | sort -V | head -10 || echo "    (no standard dist files found)"
        echo "  Alternative problems (alt-dist15-alt-dist20):"
        ls -1 input/alt-dist* 2>/dev/null | sort -V | head -6 || echo "    (no alternative dist files found)"
        echo "  Suggested small problems: dist4, dist5, dist6 (fast testing)"
        echo "  Suggested medium problems: dist9, dist12, dist15 (moderate complexity)"
        echo "  Suggested large problems: dist17, dist18, dist19 (challenging)"
        exit $E_BADARGS
    fi
    
    # Select program version
    local program
    if ! program=$(select_program_version "$requested_version"); then
        exit $E_BADARGS
    fi
    
    # Print job summary
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${BLUE}           TSP Solver Job Submission${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo "Nodes: $nodes"
    echo "Processors per node: $ppn"
    echo "Total MPI ranks: $((nodes * ppn))"
    echo "Program version: $program"
    echo "Input file: $inputfile"
    echo "Output file: $outfile"
    echo ""
    
    # Show program features
    case $program in
        "wsp-mpi_v4")
            echo -e "${GREEN}Using V4: Ultra-optimized (MPI+OpenMP, work-stealing, 2-edge bounds)${NC}"
            ;;
        "wsp-mpi_v3")
            echo -e "${GREEN}Using V3: Work-stealing version${NC}"
            ;;
        "wsp-mpi_v2")
            echo -e "${GREEN}Using V2: Enhanced with OpenMP${NC}"
            ;;
        "wsp-mpi")
            echo -e "${GREEN}Using V1: Basic MPI version${NC}"
            ;;
    esac
    echo ""
    
    # Detect environment and run accordingly
    local env=$(detect_environment)
    case $env in
        "pbs")
            echo -e "${GREEN}PBS environment detected (qsub available)${NC}"
            submit_pbs $nodes $ppn $outfile $inputfile $program
            ;;
        "local")
            echo -e "${YELLOW}Local environment (no qsub found)${NC}"
            run_local $nodes $ppn $outfile $inputfile $program
            ;;
        *)
            echo -e "${RED}Unknown environment${NC}" >&2
            exit 1
            ;;
    esac
}

# Handle script being sourced vs executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi