#!/bin/sh

set -e

# Paths
JMX_FILE="/jmeter/hivesense_api.jmx"
RESULTS_DIR="/test/jmeter_results"
JTL_FILE="$RESULTS_DIR/test_results.jtl"
LOG_FILE="$RESULTS_DIR/jmeter.log"
HTML_REPORT_DIR="$RESULTS_DIR/html-report"
WORKERS=20
LOOPS=250
TEST_TYPE="all"

print_help () {
cat <<-EOF
  Usage: $0 [OPTION[=VALUE]]...

  Run JMeter benchmark tests for HiveSense API
  
  OPTIONS:
    --workers=NUMBER       Number of threads for each query. Default: 20
    --loops=NUMBER         Number of loops for each query. Default: 250
    --test=TYPE            Test type to run. Options: all, pattern10, pattern10_with_start_parameters, pattern20, pattern50,
                           pattern100, pattern200, pattern500, pattern1000, post1, post2, patternlength_10_observer,
                           getpostbypost2_observer, thematic, thematic_observer
                           Default: all
    --help,-h,-?           Display this help screen and exit
EOF
}

# Process arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --workers=*)
        WORKERS="${1#*=}"
        ;;
    --loops=*)
        LOOPS="${1#*=}"
        ;;
    --test=*)
        TEST_TYPE="${1#*=}"
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid positional argument"
        exit 1
        ;;
    esac
    shift
done

echo "====================================================="
echo "Starting benchmark with: WORKERS=$WORKERS, LOOPS=$LOOPS, TEST=$TEST_TYPE"
echo "====================================================="

# Run test
mkdir -p "$RESULTS_DIR"

echo "Running JMeter test plan..."
# Clean up any old results file to ensure fresh start
rm -f "$JTL_FILE"

# Create a temporary copy of the JMX file that we can modify
TEMP_JMX_FILE=$(mktemp)
cp "$JMX_FILE" "$TEMP_JMX_FILE"

# Update all thread counts in the XML file
sed -i "s/<stringProp name=\"ThreadGroup.num_threads\">20<\/stringProp>/<stringProp name=\"ThreadGroup.num_threads\">$WORKERS<\/stringProp>/g" "$TEMP_JMX_FILE"
sed -i "s/<stringProp name=\"ThreadGroup.num_threads\">\${threads_count}<\/stringProp>/<stringProp name=\"ThreadGroup.num_threads\">$WORKERS<\/stringProp>/g" "$TEMP_JMX_FILE"

# Update all loop counts in the XML file
sed -i "s/<stringProp name=\"LoopController.loops\">\${loops_count}<\/stringProp>/<stringProp name=\"LoopController.loops\">$LOOPS<\/stringProp>/g" "$TEMP_JMX_FILE"

# Determine which test groups to enable
if [ "$TEST_TYPE" != "all" ]; then
    # First, disable all thread groups
    sed -i 's/testname=".*" enabled="true"/testname="&" enabled="false"/g' "$TEMP_JMX_FILE"

    # Then enable only the requested test
    case "$TEST_TYPE" in
        pattern10)
            sed -i 's/testname="PatternLength_10" enabled="false"/testname="PatternLength_10" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern10_with_start_parameters)
            sed -i 's/testname="PatternLength_10_With_Start_Parameters" enabled="false"/testname="PatternLength_10_With_Start_Parameters" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern20)
            sed -i 's/testname="PatternLength_20" enabled="false"/testname="PatternLength_20" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern50)
            sed -i 's/testname="PatternLength_50" enabled="false"/testname="PatternLength_50" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern100)
            sed -i 's/testname="PatternLength_100" enabled="false"/testname="PatternLength_100" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern200)
            sed -i 's/testname="PatternLength_200" enabled="false"/testname="PatternLength_200" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern500)
            sed -i 's/testname="PatternLength_500" enabled="false"/testname="PatternLength_500" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        pattern1000)
            sed -i 's/testname="PatternLength_1000" enabled="false"/testname="PatternLength_1000" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        post1)
            sed -i 's/testname="GetPostByPost1" enabled="false"/testname="GetPostByPost1" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        post2)
            sed -i 's/testname="GetPostByPost2" enabled="false"/testname="GetPostByPost2" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        patternlength_10_observer)
            sed -i 's/testname="PatternLength_10_Observer" enabled="false"/testname="PatternLength_10_Observer" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        getpostbypost2_observer)
            sed -i 's/testname="GetPostByPost2_Observer" enabled="false"/testname="GetPostByPost2_Observer" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        thematic)
            sed -i 's/testname="ThematicContributors" enabled="false"/testname="ThematicContributors" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        thematic_observer)
            sed -i 's/testname="ThematicContributors_Observer" enabled="false"/testname="ThematicContributors_Observer" enabled="true"/g' "$TEMP_JMX_FILE"
            ;;
        *)
            echo "ERROR: Unknown test type '$TEST_TYPE'"
            exit 1
            ;;
    esac
fi

# Run with the modified file
jmeter -n -t "$TEMP_JMX_FILE" -l "$JTL_FILE" -j "$LOG_FILE" -L DEBUG \
  -Jjmeter.save.saveservice.output_format=csv \
  -Jjmeter.save.saveservice.print_field_names=true \
  -Jjmeter.save.saveservice.assertion_results_failure_message=true \
  -Jjmeter.save.saveservice.timestamp_format=ms

# Check if JMeter ran successfully (exit code 0)
JMETER_EXIT_CODE=$?
if [ $JMETER_EXIT_CODE -ne 0 ]; then
  echo "ERROR: JMeter test failed with exit code $JMETER_EXIT_CODE"
  cat "$LOG_FILE"
  # Clean up the temporary file before exiting
  rm "$TEMP_JMX_FILE"
  exit $JMETER_EXIT_CODE
fi

# Check for failed samplers in the JTL file
if [ -f "$JTL_FILE" ]; then
  FAILURES=$(grep -c "false" "$JTL_FILE" || true)
  if [ "$FAILURES" -gt 0 ]; then
    echo "ERROR: JMeter test completed with $FAILURES failed requests"
    # We still generate the report, but will exit with error code later
    FAILED_TEST=1
  fi
fi

# Clean up the temporary file
rm "$TEMP_JMX_FILE"

echo "Generating HTML report..."
jmeter -g "$JTL_FILE" -o "$HTML_REPORT_DIR"

# Fix permissions
echo "Setting world-readable permissions..."
chmod -R a+r "$RESULTS_DIR"
find "$RESULTS_DIR" -type d -exec chmod a+x {} \;

# Fix ownership
if [ -n "$HOST_UID" ] && [ -n "$HOST_GID" ]; then
  echo "Changing ownership to UID:$HOST_UID GID:$HOST_GID..."
  chown -R "$HOST_UID:$HOST_GID" "$RESULTS_DIR"
else
  echo "⚠️ HOST_UID and HOST_GID not provided. Files will remain owned by root."
fi

echo "====================================================="
echo "Benchmark completed with: WORKERS=$WORKERS, LOOPS=$LOOPS, TEST=$TEST_TYPE"
TOTAL_TESTS=1
if [ "$TEST_TYPE" = "all" ]; then
    TOTAL_TESTS=11
fi
echo "Total requests: $((WORKERS * LOOPS * TOTAL_TESTS))"
echo "Open jmeter_results/html-report/index.html to view results"
echo "====================================================="

# Exit with error if there were failed tests
if [ "${FAILED_TEST:-0}" -eq 1 ]; then
  echo "ERROR: JMeter test had failed requests. See report for details."
  exit 1
fi