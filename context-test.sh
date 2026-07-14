#!/usr/bin/env bash
# ============================================================
# eGPU Long Context Stress Test
# ============================================================
# Tests context windows from 1K to 40K tokens.
# Uses varied technical corpus (not repeated sentences) to
# prevent prompt caching from hiding real memory pressure.
#
# Usage:
#   chmod +x context-test.sh
#   nohup bash context-test.sh &
#
# Results: ./context-test-results.txt
# ============================================================

RESULTS="./context-test-results.txt"
OLLAMA="http://localhost:11434"
MODEL="qwen3:14b-q4_K_M"

log() { echo "[$(date '+%H:%M:%S')] $1" >> "$RESULTS"; }

> "$RESULTS"
log "=========================================="
log "eGPU Long Context Stress Test"
log "Started: $(date)"
log "Model context_length: 40960 tokens"
log "=========================================="

# Pre-flight
log ""
log "=== PRE-FLIGHT ==="
log "  RAM: $(free -h | awk '/^Mem:/{print $2" total, "$3" used, "$7" available"}')"
log "  VRAM used: $(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 'N/A')"
log "  VRAM total: $(cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null || echo 'N/A')"
log "  GPU errors: $(dmesg 2>/dev/null | grep -ci 'amdgpu.*error\|amdgpu.*fault\|BUG.*amdgpu' || echo '0')"

# Generate test corpus — real varied text, not repeated sentences
generate_corpus() {
    local target_words=$1
    python3 -c "
paragraphs = [
    'The architecture of modern distributed systems relies heavily on consensus protocols. Raft and Paxos represent two fundamental approaches to achieving agreement across unreliable networks. While Paxos was the first to be formally proven correct, Raft was designed specifically for understandability. The key insight is that leader election, log replication, and safety can be decomposed into relatively independent subproblems.',
    'Database indexing strategies have evolved significantly with the rise of SSDs. Traditional B-tree indexes were optimized for spinning disk seek times, but LSM trees offer better write amplification characteristics on flash storage. RocksDB popularized this approach, and it now underpins everything from MySQL storage engines to distributed key-value stores like CockroachDB and TiKV.',
    'The CAP theorem states that a distributed data store cannot simultaneously provide more than two of consistency, availability, and partition tolerance. In practice, network partitions are inevitable, so the real choice is between CP and AP systems. However, the PACELC theorem extends this by noting that even when the system is running normally without partitions, there is still a tradeoff between latency and consistency.',
    'Memory management in systems programming languages has traditionally been a source of security vulnerabilities. Buffer overflows, use-after-free bugs, and double-free errors account for roughly seventy percent of CVEs in major software projects. Rust addresses this through its ownership model, which tracks lifetimes at compile time without runtime overhead. The borrow checker ensures that references never outlive the data they point to.',
    'Machine learning model serving at scale introduces unique challenges around batching, caching, and resource allocation. GPU memory fragmentation can reduce effective throughput by forty percent if not managed carefully. Techniques like continuous batching, KV cache reuse, and speculative decoding have emerged to maximize hardware utilization while maintaining acceptable latency percentiles.',
    'The evolution of container orchestration from Docker Swarm to Kubernetes represents a broader industry shift toward declarative infrastructure. Kubernetes pods, services, and ingress resources provide a uniform abstraction layer that decouples application deployment from the underlying compute substrate. The operator pattern extends this further by encoding domain-specific operational knowledge into custom controllers.',
    'Cryptographic hash functions serve as the foundation for numerous security primitives. SHA-256 provides collision resistance under the assumption that no polynomial-time algorithm can find two distinct inputs producing the same output. This property enables Merkle trees, which in turn enable efficient verification of large datasets. Blockchain systems leverage this for tamper-evident transaction logs.',
    'Network protocol design involves fundamental tradeoffs between reliability, latency, and throughput. TCP provides ordered reliable delivery through sequence numbers, acknowledgments, and retransmission, but introduces head-of-line blocking that affects multiplexed streams. QUIC addresses this by implementing per-stream flow control at the transport layer, eliminating the HOL blocking problem that plagued HTTP/2 over TCP.',
    'Compiler optimization passes transform intermediate representations to improve runtime performance. Dead code elimination, constant folding, loop unrolling, and function inlining are classical techniques. Modern compilers also perform interprocedural analysis, escape analysis for heap-to-stack conversion, and auto-vectorization to leverage SIMD instructions. The LLVM framework provides a modular infrastructure for implementing these passes.',
    'Observability in distributed systems encompasses three pillars: logs, metrics, and traces. Structured logging with correlation IDs enables request-level debugging across service boundaries. Prometheus-style metrics provide aggregated time-series data for alerting and capacity planning. Distributed tracing systems like Jaeger and Zipkin record the causal relationships between operations, enabling latency analysis and dependency mapping.',
    'The PageRank algorithm models the web as a directed graph where each page is a node and each hyperlink is an edge. The rank of a page is determined by the number and quality of pages linking to it, computed iteratively until convergence. This approach revolutionized web search by providing a query-independent measure of page importance, fundamentally different from the keyword-matching approaches that preceded it.',
    'Functional programming paradigms emphasize immutability and referential transparency. Pure functions always return the same output for the same input and produce no side effects. This property enables equational reasoning, aggressive compiler optimizations, and straightforward parallelization. Languages like Haskell enforce purity through the type system, using monads to encapsulate effectful computations.',
    'Load balancing algorithms range from simple round-robin to sophisticated least-connections approaches with health checking. Consistent hashing provides a particularly elegant solution for distributed caches, ensuring that adding or removing nodes only redistributes a fraction of the keys. The jump hash variant achieves this with constant memory and zero allocations, making it suitable for high-throughput proxy implementations.',
    'Version control systems track changes to source code over time. Git uses a content-addressable object store where every file, directory tree, and commit is identified by its SHA-1 hash. This design enables efficient branching and merging, as branches are simply pointers to commits. The reflog provides an additional safety net, recording every change to branch references even when commits become unreachable.',
    'Real-time systems impose strict timing constraints on computation. Hard real-time systems like flight controllers require guaranteed worst-case execution times. Rate-monotonic scheduling provides an optimal fixed-priority assignment for periodic tasks. The schedulability test ensures that the total CPU utilization remains below a bound determined by the number of tasks, preventing deadline misses under all circumstances.',
    'Graph databases model relationships as first-class entities, enabling efficient traversal of connected data. Property graphs associate key-value pairs with both nodes and edges, supporting rich queries about relationship attributes. Cypher and Gremlin provide declarative and imperative query languages respectively. Common use cases include social networks, recommendation engines, fraud detection, and knowledge graphs.',
]

words_per_para = 80
needed_paras = ($target_words // words_per_para) + 1
output = []
for i in range(needed_paras):
    idx = i % len(paragraphs)
    marker = f'Section {i+1} of {needed_paras}.'
    output.append(f'{marker} {paragraphs[idx]}')
print(' '.join(output))
" 2>/dev/null
}

run_context_test() {
    local ctx_tokens=$1
    local label=$2
    local num_ctx=$3

    local target_words=$((ctx_tokens * 3 / 4))

    log ""
    log "--- Context test: ~${ctx_tokens} tokens (num_ctx=${num_ctx}) ---"

    local corpus
    corpus=$(generate_corpus "$target_words")
    local actual_words=$(echo "$corpus" | wc -w | tr -d ' ')
    log "  Generated corpus: ${actual_words} words"

    local vram_before=$(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo "0")

    # Write payload to file to avoid shell string size limits at 32K+
    local payload_file=$(mktemp /tmp/ctx-payload-XXXXXX.json)
    python3 -c "
import json, sys
corpus = sys.stdin.read()
payload = {
    'model': '$MODEL',
    'prompt': 'Read the following technical content carefully. After reading, answer this question: What are the three main topics discussed in the text? List them briefly.\n\n' + corpus + '\n\nNow list the three main topics:',
    'stream': False,
    'options': {'num_predict': 256, 'num_ctx': $num_ctx}
}
json.dump(payload, open('$payload_file', 'w'))
" <<< "$corpus"

    local start_ms=$(date +%s%3N)
    local response
    response=$(curl -s --max-time 600 "$OLLAMA/api/generate" -d @"$payload_file" 2>/dev/null)
    local exit_code=$?
    local end_ms=$(date +%s%3N)
    local wall_ms=$((end_ms - start_ms))
    rm -f "$payload_file"

    if [ $exit_code -ne 0 ] || [ -z "$response" ]; then
        log "  [$label] FAILED (timeout or error after ${wall_ms}ms)"
        local ollama_status=$(systemctl is-active ollama 2>/dev/null)
        log "  [$label] Ollama status: $ollama_status"
        local gpu_errors=$(dmesg 2>/dev/null | grep -ci 'amdgpu.*error\|amdgpu.*fault\|BUG.*amdgpu' || echo '0')
        log "  [$label] GPU errors: $gpu_errors"
        return 1
    fi

    local error_msg=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null)
    if [ -n "$error_msg" ] && [ "$error_msg" != "" ]; then
        log "  [$label] ERROR: $error_msg"
        return 1
    fi

    local eval_count=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_count',0))" 2>/dev/null || echo "0")
    local eval_duration=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('eval_duration',0))" 2>/dev/null || echo "0")
    local prompt_eval_count=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_count',0))" 2>/dev/null || echo "0")
    local prompt_eval_duration=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('prompt_eval_duration',0))" 2>/dev/null || echo "0")

    local gen_tps="0"
    if [ "$eval_duration" -gt 0 ] 2>/dev/null; then
        gen_tps=$(python3 -c "print(f'{$eval_count / ($eval_duration / 1e9):.1f}')" 2>/dev/null || echo "?")
    fi

    local prompt_tps="0"
    if [ "$prompt_eval_duration" -gt 0 ] 2>/dev/null; then
        prompt_tps=$(python3 -c "print(f'{$prompt_eval_count / ($prompt_eval_duration / 1e9):.1f}')" 2>/dev/null || echo "?")
    fi

    local vram_after=$(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo "0")
    local vram_delta_mb=$(python3 -c "print(f'{($vram_after - $vram_before) / 1048576:.0f}')" 2>/dev/null || echo "?")

    local snippet=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('response','')[:150].replace(chr(10),' '))" 2>/dev/null || echo "?")

    log "  [$label] OK: prompt=${prompt_eval_count}tok gen=${eval_count}tok"
    log "  [$label] prompt_speed=${prompt_tps}tok/s gen_speed=${gen_tps}tok/s wall=${wall_ms}ms"
    log "  [$label] VRAM delta: ${vram_delta_mb}MB"
    log "  [$label] >>> ${snippet}"
    return 0
}

# ============================================================
# Context ladder — escalating sizes
# ============================================================
log ""
log "=== CONTEXT LADDER ==="

# Warm the model
curl -s "$OLLAMA/api/generate" -d "{\"model\":\"$MODEL\",\"prompt\":\"hello\",\"stream\":false,\"options\":{\"num_predict\":1}}" > /dev/null 2>&1
sleep 2

run_context_test 1000 "ctx-1k" 2048
sleep 3
run_context_test 2000 "ctx-2k" 4096
sleep 3
run_context_test 4000 "ctx-4k" 8192
sleep 3
run_context_test 8000 "ctx-8k" 16384
sleep 3
run_context_test 16000 "ctx-16k" 24576
sleep 3
run_context_test 24000 "ctx-24k" 32768
sleep 3
run_context_test 32000 "ctx-32k" 40960
sleep 3

log ""
log "=== BEYOND RATED CONTEXT (40960) ==="
run_context_test 38000 "ctx-38k" 40960
sleep 3

# ============================================================
# Sustained long-context (30 min at 8K context)
# ============================================================
log ""
log "=== SUSTAINED LONG CONTEXT (30 min at ~8K tokens) ==="

lc_start=$(date +%s)
lc_end=$((lc_start + 1800))
lc_count=0
lc_failures=0

while [ $(date +%s) -lt $lc_end ]; do
    lc_count=$((lc_count + 1))
    if ! run_context_test 8000 "sustained-8k-${lc_count}" 16384; then
        lc_failures=$((lc_failures + 1))
        if [ $lc_failures -ge 3 ]; then
            log "  3+ failures — aborting sustained test"
            break
        fi
        sleep 5
    fi
    sleep 2
done

lc_elapsed=$(($(date +%s) - lc_start))
log ""
log "Sustained long-context complete: $lc_count iterations in ${lc_elapsed}s, $lc_failures failures"

# ============================================================
# POST-TEST
# ============================================================
log ""
log "=== POST-TEST HEALTH ==="
log "  RAM: $(free -h | awk '/^Mem:/{print $3" used, "$7" available"}')"
log "  VRAM: $(cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null || echo 'N/A')"
log "  GPU errors: $(dmesg 2>/dev/null | grep -ci 'amdgpu.*error\|amdgpu.*fault\|BUG.*amdgpu' || echo '0')"
log "  Ollama: $(systemctl is-active ollama)"
log "  Uptime: $(uptime -p)"

log ""
log "=========================================="
log "CONTEXT TEST COMPLETE"
log "Finished: $(date)"
log "=========================================="
