#!/bin/sh

set -e

# Paths
JMX_FILE="/jmeter/hivesense_api.jmx"
RESULTS_DIR="/test/jmeter_results"
JTL_FILE="$RESULTS_DIR/test_results.jtl"
LOG_FILE="$RESULTS_DIR/jmeter.log"
HTML_REPORT_DIR="$RESULTS_DIR/html-report"

# Run test
mkdir -p "$RESULTS_DIR"

echo "Running JMeter test plan..."
jmeter -n -t "$JMX_FILE" -l "$JTL_FILE" -j "$LOG_FILE"

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

echo "Done! Open jmeter_results/html-report/index.html"
