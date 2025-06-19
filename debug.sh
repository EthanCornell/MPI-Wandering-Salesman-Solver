#!/bin/bash
#
# debug_run_job.sh - Simple test to debug run_job.sh issues
#

echo "=== Debugging run_job.sh ==="

# Test basic functionality
echo "1. Testing run_job.sh existence and permissions:"
if [[ -f "./run_job.sh" ]]; then
    echo "   ✓ run_job.sh exists"
    if [[ -x "./run_job.sh" ]]; then
        echo "   ✓ run_job.sh is executable"
    else
        echo "   ✗ run_job.sh is not executable"
        echo "   Fix with: chmod +x run_job.sh"
        exit 1
    fi
else
    echo "   ✗ run_job.sh not found"
    exit 1
fi

echo ""
echo "2. Testing run_job.sh help:"
./run_job.sh 2>/dev/null || echo "   (showing usage is normal)"

echo ""
echo "3. Testing simple run_job.sh call:"
echo "   Command: ./run_job.sh 1 4 debug_test.log input/dist15 wsp-mpi_v4"

# Run with verbose output
if ./run_job.sh 1 4 debug_test.log input/dist15 wsp-mpi_v4; then
    echo "   ✓ run_job.sh completed successfully"
    
    if [[ -f "debug_test.log" ]]; then
        echo "   ✓ Output file created"
        echo "   File size: $(wc -l < debug_test.log) lines"
        echo ""
        echo "   === First 10 lines of output ==="
        head -10 debug_test.log
        echo "   === Last 10 lines of output ==="
        tail -10 debug_test.log
        echo ""
        
        # Test extraction
        echo "4. Testing result extraction:"
        time_found=$(grep -E "(time:|elapsed)" debug_test.log | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        cost_found=$(grep -E "(cost:|best=)" debug_test.log | tail -1 | grep -oE '[0-9]+' | head -1)
        
        echo "   Time found: '$time_found'"
        echo "   Cost found: '$cost_found'"
        
        if [[ -n "$time_found" && -n "$cost_found" ]]; then
            echo "   ✓ Extraction successful"
        else
            echo "   ✗ Extraction failed"
            echo "   === Lines containing 'time' or 'cost' ==="
            grep -E "(time|cost|best|elapsed)" debug_test.log || echo "   (no matching lines found)"
        fi
        
        # Cleanup
        rm -f debug_test.log debug_test.pbs
    else
        echo "   ✗ Output file not created"
    fi
else
    echo "   ✗ run_job.sh failed"
    exit 1
fi

echo ""
echo "=== Debug complete ==="