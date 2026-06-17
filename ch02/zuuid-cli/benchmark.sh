#!/bin/bash

# 1. Build the Zig project in Release Mode
# We use ReleaseFast to strip debug checks and enable full optimizations.
echo "Compiling zuuid-cli in ReleaseFast mode..."
zig build -Doptimize=ReleaseFast

# Verify the binary exists
ZIG_BIN="./zig-out/bin/zuuid-cli"
if [ ! -f "$ZIG_BIN" ]; then
    echo "Error: Binary not found at $ZIG_BIN"
    exit 1
fi

# 2. Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo "Error: 'hyperfine' is not installed."
    echo "Install it via: brew install hyperfine (macOS) or apt install hyperfine (Linux)"
    exit 1
fi

# 3. Run the Benchmark
# We compare generating 1 single UUID to measure startup time + generation cost.
echo "Starting Benchmark..."
echo "---------------------------------------------------"

hyperfine --warmup 5 \
    --export-markdown benchmark_results.md \
    -N \
    -n "System uuidgen" "uuidgen" \
    -n "Zig zuuid (ReleaseFast)" "$ZIG_BIN -n 1"


echo "---------------------------------------------------"
echo "Results saved to benchmark_results.md"
