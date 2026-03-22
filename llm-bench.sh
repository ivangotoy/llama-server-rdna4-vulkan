#!/usr/bin/env bash
set -euo pipefail

PORT=8081
BACKEND="${1:-}"
RUNS="${2:-10}"
WARMUP=2
OUT_DIR="${HOME}/llm-bench-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MODEL="qwen3"
MAX_TOKENS=512

PROMPT="You are a senior Linux systems engineer. Explain in detail how the Linux kernel manages memory pressure: describe the roles of kswapd, direct reclaim, OOM killer, and memory cgroups, and how they interact when a system approaches memory exhaustion. Include specific kernel tunable parameters relevant to each mechanism."

if [[ -z "$BACKEND" ]]; then
  echo "Usage: $0 <llama|vllm> [runs=10]"
  echo "  Ensure the target service is running on :${PORT} before calling this."
  exit 1
fi

mkdir -p "$OUT_DIR"
RESULT_FILE="${OUT_DIR}/${BACKEND}_${TIMESTAMP}.jsonl"
SUMMARY_FILE="${OUT_DIR}/${BACKEND}_${TIMESTAMP}_summary.txt"

wait_for_ready() {
  local retries=30
  echo "Waiting for service on :${PORT}..."
  for ((i=1; i<=retries; i++)); do
    if curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
      echo "Service ready."
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Service not ready after $((retries * 2))s" >&2
  exit 1
}

do_request() {
  local label="$1"
  local run_num="$2"

  local t_start t_end
  t_start=$(date +%s%3N)

  local response
  response=$(curl -sf \
    -X POST "http://localhost:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"${MODEL}\",
      \"messages\": [{\"role\": \"user\", \"content\": $(python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))' <<< "$PROMPT")}],
      \"max_tokens\": ${MAX_TOKENS},
      \"stream\": false,
      \"temperature\": 0,
      \"seed\": 42
    }")

  t_end=$(date +%s%3N)

  local elapsed_ms=$(( t_end - t_start ))
  local elapsed_s
  elapsed_s=$(echo "scale=3; $elapsed_ms / 1000" | bc)

  local prompt_tokens completion_tokens finish_reason tps
  prompt_tokens=$(echo "$response"     | python3 -c "import json,sys; print(json.load(sys.stdin)['usage']['prompt_tokens'])"      2>/dev/null || echo "0")
  completion_tokens=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin)['usage']['completion_tokens'])"  2>/dev/null || echo "0")
  finish_reason=$(echo "$response"     | python3 -c "import json,sys; print(json.load(sys.stdin)['choices'][0]['finish_reason'])" 2>/dev/null || echo "unknown")

  tps=0
  if [[ "$completion_tokens" -gt 0 ]]; then
    tps=$(echo "scale=2; $completion_tokens / $elapsed_s" | bc)
  fi

  printf "  [%s %2d/%d]  in=%-4s out=%-4s tok  elapsed=%-7s s  tps=%-8s  finish=%s\n" \
    "$label" "$run_num" "$RUNS" "$prompt_tokens" "$completion_tokens" "$elapsed_s" "$tps" "$finish_reason"

  if [[ "$label" != "warmup" ]]; then
    echo "{\"backend\":\"${BACKEND}\",\"run\":${run_num},\"prompt_tokens\":${prompt_tokens},\"completion_tokens\":${completion_tokens},\"elapsed_ms\":${elapsed_ms},\"tps\":${tps},\"finish_reason\":\"${finish_reason}\"}" \
      >> "$RESULT_FILE"
  fi
}

print_summary() {
  python3 - "$RESULT_FILE" "$BACKEND" <<'PYEOF'
import json, sys, statistics

f, backend = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(f)]

tps  = [float(r["tps"])          for r in rows]
ela  = [r["elapsed_ms"] / 1000.0 for r in rows]
ctok = [r["completion_tokens"]   for r in rows]

w = 52
print(f"\n{'='*w}")
print(f"  SUMMARY  {backend.upper()}  ({len(rows)} runs, warmup excluded)")
print(f"{'='*w}")
print(f"  Output tokens  min={min(ctok)}  max={max(ctok)}  avg={statistics.mean(ctok):.1f}")
print(f"  Elapsed   (s)  min={min(ela):.2f}  max={max(ela):.2f}  avg={statistics.mean(ela):.2f}  stdev={statistics.stdev(ela):.3f}")
print(f"  Tok/s          min={min(tps):.1f}  max={max(tps):.1f}  avg={statistics.mean(tps):.1f}  median={statistics.median(tps):.1f}  stdev={statistics.stdev(tps):.2f}")
finishes = {}
for r in rows:
    finishes[r["finish_reason"]] = finishes.get(r["finish_reason"], 0) + 1
print(f"  Finish reasons {finishes}")
print(f"{'='*w}\n")
PYEOF
}

echo "============================================================"
echo "  Backend  : ${BACKEND}"
echo "  Runs     : ${RUNS}  (+ ${WARMUP} warmup discarded)"
echo "  Model    : ${MODEL}"
echo "  MaxTok   : ${MAX_TOKENS}  |  Temp: 0  |  Seed: 42"
echo "  Output   : ${RESULT_FILE}"
echo "============================================================"

wait_for_ready

echo ""
echo "── Warmup (discarded) ──────────────────────────────────────"
for ((w=1; w<=WARMUP; w++)); do
  do_request "warmup" "$w"
  sleep 1
done

echo ""
echo "── Measured runs ───────────────────────────────────────────"
for ((r=1; r<=RUNS; r++)); do
  do_request "run" "$r"
  sleep 1
done

print_summary | tee "$SUMMARY_FILE"
echo "Raw    : ${RESULT_FILE}"
echo "Summary: ${SUMMARY_FILE}"
