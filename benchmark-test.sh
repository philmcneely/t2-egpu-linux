#!/usr/bin/env bash
# ============================================================
# eGPU Inference Benchmark — Stability + Throughput
# ============================================================
# Runs directly on the inference machine. No external deps.
# Tests cold start, warm throughput, context stress, reasoning
# quality, 60-min sustained load, and concurrent requests.
#
# Usage:
#   chmod +x benchmark-test.sh
#   nohup bash benchmark-test.sh &
#
# Results: ./benchmark-results.txt
# ============================================================

RESULTS="./benchmark-results.txt"
OLLAMA="http://localhost:11434"
MODEL="qwen3:14b-q4_K_M"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$RESULTS"; }

> "$RESULTS"
log "=========================================="
log "eGPU Inference Benchmark"
log "Started: $(date)"
log "=========================================="

# ---- Helper ----
run_inference() {
    local prompt="$1"
    local label="$2"
    local timeout="${3:-120}"
    local num_predict="${4:-256}"

    local response
    response=$(curl -s --max-time "$timeout" "$OLLAMA/api/generate" -d "{
        \"model\": \"$MODEL\",
        \"prompt\": \"$prompt\",
        \"stream\": false,
        \"options\": {\"num_predict\": $num_predict}
    }" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log "  [$label] FAILED (timeout or connection error)"
        return 1
    fi

    local eval_count eval_duration load_duration prompt_eval_count tok_per_sec load_sec snippet
    eval_count=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))" 2>/dev/null || echo "0")
    eval_duration=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_duration',0))" 2>/dev/null || echo "0")
    load_duration=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('load_duration',0))" 2>/dev/null || echo "0")
    prompt_eval_count=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_count',0))" 2>/dev/null || echo "0")

    if [ "$eval_duration" -gt 0 ] 2>/dev/null; then
        tok_per_sec=$(python3 -c "print(f'{$eval_count / ($eval_duration / 1e9):.1f}')" 2>/dev/null || echo "?")
    else
        tok_per_sec="0"
    fi
    load_sec=$(python3 -c "print(f'{$load_duration / 1e9:.2f}')" 2>/dev/null || echo "?")

    snippet=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response','')[:120].replace(chr(10),' '))" 2>/dev/null || echo "?")

    log "  [$label] OK: gen=${eval_count}tok prompt=${prompt_eval_count}tok ${tok_per_sec}tok/s load=${load_sec}s"
    log "  [$label] >>> ${snippet}"
    return 0
}

# ============================================================
# PRE-FLIGHT
# ============================================================
log ""
log "=== PRE-FLIGHT ==="
log "  RAM: $(free -h | awk '/^Mem:/{print $2" total, "$3" used, "$7" available"}')"
log "  Disk: $(df -h / | awk 'NR==2{print $4" free of "$2}')"
log "  Uptime: $(uptime -p)"
log "  Ollama: $(systemctl is-active ollama)"
log "  GPU errors in dmesg: $(dmesg 2>/dev/null | grep -ci 'amdgpu.*error\|amdgpu.*fault\|BUG.*amdgpu' || echo '0')"
log "  VRAM used: $(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 'N/A')"
log "  VRAM total: $(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo 'N/A')"

# ============================================================
# TEST 1: Cold Start
# ============================================================
log ""
log "=== TEST 1: COLD START ==="
curl -s "$OLLAMA/api/generate" -d "{\"model\":\"$MODEL\",\"keep_alive\":0}" > /dev/null 2>&1
sleep 5
log "Model unloaded. Cold-starting $MODEL..."
run_inference "What is 2+2? Answer in one word." "cold-start" 300 32

# ============================================================
# TEST 2: Warm Performance (20 runs)
# ============================================================
log ""
log "=== TEST 2: WARM PERFORMANCE (20 runs) ==="

PROMPTS=(
    "Explain quantum entanglement to a 10-year-old."
    "Write a haiku about debugging."
    "What are three causes of inflation?"
    "Describe how a TCP handshake works."
    "Name five programming languages and their best use case."
    "Stack vs queue — what is the difference?"
    "Explain technical debt using a metaphor."
    "How does garbage collection work in Go?"
    "What is a bloom filter? When would you use one?"
    "Describe the CAP theorem."
    "What is the difference between REST and GraphQL?"
    "Explain how DNS resolution works step by step."
    "What is eventual consistency?"
    "Describe the observer pattern with a real example."
    "What is memoization and when should you use it?"
    "How does public key cryptography work?"
    "Explain the difference between threads and processes."
    "What is a race condition? Give an example."
    "Describe how a B-tree index works in a database."
    "What is the halting problem and why does it matter?"
)

for i in "${!PROMPTS[@]}"; do
    run_inference "${PROMPTS[$i]}" "warm-$((i+1))" 120 256
    sleep 1
done

# ============================================================
# TEST 3: Context Length Stress
# ============================================================
log ""
log "=== TEST 3: CONTEXT LENGTH STRESS ==="

for ctx_words in 500 1000 2000 4000 8000 16000; do
    filler=$(python3 -c "
words = 'The quick brown fox jumps over the lazy dog near the river bank where fish swim upstream against the current while birds circle overhead watching for prey in the shallow water below'.split()
import itertools
out = list(itertools.islice(itertools.cycle(words), $ctx_words))
print(' '.join(out))
" 2>/dev/null)
    prompt="Read the following text carefully and count how many times the word 'fox' appears: $filler. How many times does 'fox' appear?"
    log "  Context test: ~${ctx_words} words input"
    run_inference "$prompt" "ctx-${ctx_words}w" 300 128
    sleep 2
done

log ""
log "  Post-context RAM: $(free -h | awk '/^Mem:/{print $3" used, "$7" available"}')"
log "  Post-context VRAM: $(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 'N/A')"

# ============================================================
# TEST 4: Quality / Reasoning
# ============================================================
log ""
log "=== TEST 4: QUALITY / REASONING ==="

run_inference "If it takes 5 machines 5 minutes to make 5 widgets, how long would it take 100 machines to make 100 widgets? Think step by step." "reason-widgets" 120 512

run_inference "A farmer has 17 sheep. All but 9 die. How many sheep are left? Explain your answer." "reason-sheep" 120 256

run_inference "Write a Python function that reverses a linked list iteratively. Include the ListNode class definition." "code-linkedlist" 120 512

run_inference "You have a 3-gallon jug and a 5-gallon jug. How do you measure exactly 4 gallons of water? Show each step." "reason-jugs" 120 512

run_inference "What is wrong with this SQL query: SELECT name, COUNT(*) FROM users WHERE age > 25 HAVING count > 5" "code-sql-debug" 120 256

run_inference "Translate this to French and then back to English: The cat sat on the mat while the dog watched from the window." "translate-roundtrip" 120 256

# ============================================================
# TEST 5: Sustained Load (60 min)
# ============================================================
log ""
log "=== TEST 5: SUSTAINED LOAD (60 min, $MODEL) ==="

STRESS_PROMPTS=(
    "Explain the difference between TCP and UDP."
    "What is a Turing machine?"
    "Describe the SOLID principles."
    "How does a hash table handle collisions?"
    "What is the halting problem?"
    "Explain eventual consistency."
    "What is memoization?"
    "Describe the observer pattern."
    "Concurrency vs parallelism — what is the difference?"
    "How does public key cryptography work?"
    "What is a deadlock and how do you prevent it?"
    "Explain MapReduce in simple terms."
    "What is the difference between SQL and NoSQL?"
    "How does a load balancer work?"
    "What is containerization and why use Docker?"
)

stress_start=$(date +%s)
stress_end=$((stress_start + 3600))
stress_count=0
stress_failures=0

while [ $(date +%s) -lt $stress_end ]; do
    idx=$((stress_count % ${#STRESS_PROMPTS[@]}))
    stress_count=$((stress_count + 1))
    if ! run_inference "${STRESS_PROMPTS[$idx]}" "stress-$stress_count" 120 256; then
        stress_failures=$((stress_failures + 1))
        log "  STRESS FAILURE #$stress_failures at iteration $stress_count"
        if [ $stress_failures -ge 5 ]; then
            log "  5+ failures — aborting stress test"
            break
        fi
        sleep 5
    fi
    sleep 1
done

stress_elapsed=$(($(date +%s) - stress_start))
log ""
log "Stress complete: $stress_count iterations in ${stress_elapsed}s, $stress_failures failures"

# ============================================================
# TEST 6: Concurrent Requests (3 simultaneous)
# ============================================================
log ""
log "=== TEST 6: CONCURRENT REQUESTS ==="

for req_id in 1 2 3; do
    (
        local_prompt="Explain concept number $req_id: $(echo 'recursion binary_search mutex' | cut -d' ' -f$req_id)"
        start_ms=$(date +%s%3N)
        resp=$(curl -s --max-time 120 "$OLLAMA/api/generate" -d "{
            \"model\": \"$MODEL\",
            \"prompt\": \"$local_prompt\",
            \"stream\": false,
            \"options\": {\"num_predict\": 128}
        }" 2>/dev/null)
        end_ms=$(date +%s%3N)
        wall=$((end_ms - start_ms))
        ec=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('eval_count',0))" 2>/dev/null || echo 0)
        ed=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('eval_duration',0))" 2>/dev/null || echo 0)
        tps=$(python3 -c "print(f'{$ec/($ed/1e9):.1f}') if $ed > 0 else print('0')" 2>/dev/null)
        log "  [concurrent-$req_id] ${ec}tok ${tps}tok/s wall=${wall}ms"
    ) &
done
wait
log "Concurrent test complete"

# ============================================================
# POST-TEST HEALTH CHECK
# ============================================================
log ""
log "=== POST-TEST HEALTH ==="
log "  RAM: $(free -h | awk '/^Mem:/{print $3" used, "$7" available"}')"
log "  VRAM: $(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 'N/A')"
log "  GPU errors: $(dmesg 2>/dev/null | grep -ci 'amdgpu.*error\|amdgpu.*fault\|BUG.*amdgpu' || echo '0')"
log "  Ollama: $(systemctl is-active ollama)"
log "  Uptime: $(uptime -p)"

# ============================================================
# SUMMARY
# ============================================================
log ""
log "=========================================="
log "TEST SUITE COMPLETE"
log "Finished: $(date)"
log "=========================================="

total_ok=$(grep -c '\] OK:' "$RESULTS" 2>/dev/null || echo "0")
total_fail=$(grep -c 'FAILED' "$RESULTS" 2>/dev/null || echo "0")
avg_tps=$(grep '\] OK:' "$RESULTS" | grep 'tok/s' | sed 's/.*[[:space:]]//' | sed 's/tok\/s//' | awk -F'tok/s' '{print $1}' | grep -oE '[0-9]+\.[0-9]+' | awk '{s+=$1;c++} END {if(c>0) printf "%.1f", s/c; else print "N/A"}')

log ""
log "SUMMARY:"
log "  Successful inferences: $total_ok"
log "  Failures: $total_fail"
log "  Avg tok/s: $avg_tps"
