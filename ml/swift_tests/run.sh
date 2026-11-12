#!/bin/sh
# Compiles the app's classifier with each test and runs it.
#   parity:     Swift features + forest vs Python on 18,943 real detections (ml/outputs/swift_golden.csv)
#   edge_cases: bad inputs, poles/dateline, sensor loss, 200k-detection load, corrupt model files
# Usage: sh ml/swift_tests/run.sh   (from the repo root)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$(mktemp -d)
for t in parity edge_cases; do
  echo "== $t"
  swiftc -O -swift-version 5 -default-isolation MainActor -o "$OUT/$t" \
    "$ROOT/MyApp/Models/FireDetection.swift" "$ROOT/MyApp/Models/FireQuery.swift" \
    "$ROOT/MyApp/ML/WildfireClassifier.swift" "$ROOT/ml/swift_tests/$t/main.swift"
  "$OUT/$t" "$ROOT"
done
