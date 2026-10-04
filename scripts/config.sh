# Settings for the three boxes. Edit here, or put overrides in scripts/local.sh (sourced last, not committed).
# Run everything from the HEAD box (rank 0, the one that serves the API).

WORKER1="${WORKER1:-}"                  # ssh target of the second box (user@host), LAN address
WORKER2="${WORKER2:-}"                  # ssh target of the third box
KINDLING_DIR="${KINDLING_DIR:-$HOME/glm53-kindling}"   # same path on all three boxes

# Pinned upstreams (what this recipe was measured on)
KINDLING_REPO="https://github.com/kindlingai/glm-5.3-flash-gx10.git"
KINDLING_REF="a3c3a1d7b2155e2e6ddc8d586d9999d27580c78e"
KSO_REPO="https://github.com/kindlingai/kindling-spark-os.git"     # dispram lives here (AGPL/GPL)
KSO_REF="73ff3ae198ba4f145a22ea859d7106721fdbd621"

# Checkpoints: kindling's experimental/tp3/make_padded.py output (TP=3 needs the zero-padded copies)
MODEL_HOST_DIR="${MODEL_HOST_DIR:-/srv/models/glm-5.3-flash-nvfp4-tp3}"
DFLASH_HOST_DIR="${DFLASH_HOST_DIR:-/srv/models/glm-5.3-flash-dflash2-tp3}"
SERVED_NAME="${SERVED_NAME:-GLM-5.3-Flash}"
API_PORT="${API_PORT:-8888}"

# Memory. 18 GiB of KV per rank (+2 GiB from dispram) ONLY together with the 21 graph sizes below: vLLM's own
# 57 sizes take ~10 GiB per rank of CUDA graphs, and at 18 GiB that leaves the head too little room.
KV_CACHE_MEMORY="${KV_CACHE_MEMORY:-19327352832}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"     # 1M starts, but a ~500k cold prompt drove the head to 2 GiB free (README)
GRAPH_SIZES="${GRAPH_SIZES:-1 8 12 15 16 24 32 48 64 80 96 112 128 160 192 224 256 320 384 448 512}"
DT_TAU="${DT_TAU:-0.3}"

# CX7: the four netdevs and RDMA devices of a GB10 box (two ports on each of two PCIe roots)
NETDEVS="${NETDEVS:-enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1}"
F0_HCAS="${F0_HCAS:-rocep1s0f0,roceP2p1s0f0}"   # port f0 on both roots
F1_HCAS="${F1_HCAS:-rocep1s0f1,roceP2p1s0f1}"   # port f1 on both roots
# Optional cable checks for the boot gate: "host src dst" per line (host = local, or WORKER1/WORKER2's value).
CABLE_CHECKS="${CABLE_CHECKS:-}"

[ -f "$(dirname "${BASH_SOURCE[0]}")/local.sh" ] && . "$(dirname "${BASH_SOURCE[0]}")/local.sh"
HOSTS=(local "$WORKER1" "$WORKER2")
run_on() { if [ "$1" = local ]; then bash -c "$2"; else ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" "$2"; fi; }
