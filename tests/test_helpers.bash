#!/usr/bin/env bash
set -euo pipefail

# Simple bash unit test framework
# Usage: ./test_helpers.bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test functions
assert_equal() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"
    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}PASS${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} $test_name"
        echo "Expected: '$expected'"
        echo "Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_true() {
    local condition="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$condition" = "true" ]; then
        echo -e "${GREEN}PASS${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_false() {
    local condition="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$condition" = "false" ]; then
        echo -e "${GREEN}PASS${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}FAIL${NC} $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source the helpers script
source "$PROJECT_DIR/scripts/helpers.sh"

echo "Running tests for helpers.sh functions..."

# Test get_log_level_num
echo
echo "Testing get_log_level_num..."
export LOG_LEVEL=DEBUG
result=$(get_log_level_num)
assert_equal 0 "$result" "DEBUG log level"

export LOG_LEVEL=INFO
result=$(get_log_level_num)
assert_equal 1 "$result" "INFO log level"

export LOG_LEVEL=WARN
result=$(get_log_level_num)
assert_equal 2 "$result" "WARN log level"

export LOG_LEVEL=ERROR
result=$(get_log_level_num)
assert_equal 3 "$result" "ERROR log level"

export LOG_LEVEL=UNKNOWN
result=$(get_log_level_num)
assert_equal 1 "$result" "Unknown log level defaults to INFO"

# Test extract_gpu_count
echo
echo "Testing extract_gpu_count..."
result=$(extract_gpu_count "1")
assert_equal "1" "$result" "Single gpu"

result=$(extract_gpu_count "2 GPUs")
assert_equal "2" "$result" "Multiple gpus string"

result=$(extract_gpu_count "")
assert_equal "0" "$result" "Empty gpu info"

result=$(extract_gpu_count "null")
assert_equal "0" "$result" "Null gpu info"

# Test adjust_weights_for_metric
echo
echo "Testing adjust_weights_for_metric..."
export VCPU_WEIGHT="1.0"
export MEM_WEIGHT="2.0"
export GPU_WEIGHT="4.0"

result=$(adjust_weights_for_metric "cpu-only")
assert_equal "1.0 0 0" "$result" "CPU only metric"

result=$(adjust_weights_for_metric "cpu+mem")
assert_equal "1.0 2.0 0" "$result" "CPU+MEM metric"

result=$(adjust_weights_for_metric "cpu+mem+gpu")
assert_equal "1.0 2.0 4.0" "$result" "CPU+MEM+GPU metric"

# Test calculate_serverclass_score
echo
echo "Testing calculate_serverclass_score..."
result=$(calculate_serverclass_score 2 4 0.005 0)
# Expected: 0.005 / (1.0*2 + 2.0*4 + 4.0*0) = 0.005 / (2 + 8 + 0) = 0.005/10 = 0.0005
assert_equal "0.000500" "$result" "Serverclass score calculation"

result=$(calculate_serverclass_score 0 0 0 0)
assert_equal "" "$result" "Zero denominator"

# Test extract_gpu_count
echo
echo "Testing extract_gpu_count..."
result=$(extract_gpu_count "1")
assert_equal "1" "$result" "Single gpu"

result=$(extract_gpu_count "2 GPUs")
assert_equal "2" "$result" "Multiple gpus string"

result=$(extract_gpu_count "")
assert_equal "0" "$result" "Empty gpu info"

result=$(extract_gpu_count "null")
assert_equal "0" "$result" "Null gpu info"

# Test adjust_weights_for_metric
echo
echo "Testing adjust_weights_for_metric..."
export VCPU_WEIGHT="1.0"
export MEM_WEIGHT="2.0"
export GPU_WEIGHT="4.0"

result=$(adjust_weights_for_metric "cpu-only")
assert_equal "1.0 0 0" "$result" "CPU only metric"

result=$(adjust_weights_for_metric "cpu+mem")
assert_equal "1.0 2.0 0" "$result" "CPU+MEM metric"

result=$(adjust_weights_for_metric "cpu+mem+gpu")
assert_equal "1.0 2.0 4.0" "$result" "CPU+MEM+GPU metric"

# Test calculate_serverclass_score
echo
echo "Testing calculate_serverclass_score..."
result=$(calculate_serverclass_score 2 4 0.005 0)
# Expected: 0.005 / (1.0*2 + 2.0*4 + 4.0*0) = 0.005 / (2 + 8 + 0) = 0.005/10 = 0.0005
assert_equal "0.000500" "$result" "Serverclass score calculation"

result=$(calculate_serverclass_score 0 0 0 0)
assert_equal "" "$result" "Zero denominator"

# Test validate_service_type
echo
echo "Testing validate_service_type..."
result=$(validate_service_type "LoadBalancer" && echo "true" || echo "false")
assert_equal "true" "$result" "Valid LoadBalancer"

result=$(validate_service_type "ClusterIP" && echo "true" || echo "false")
assert_equal "true" "$result" "Valid ClusterIP"

result=$(validate_service_type "NodePort" && echo "true" || echo "false")
assert_equal "false" "$result" "Invalid NodePort"

# Summary
echo
echo "Test Summary:"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
fi
echo "Total: $TESTS_RUN"

if [ $TESTS_FAILED -gt 0 ]; then
    exit 1
fi