
#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# cidr_used_free_ips.sh
#
# Author: Prasadu Gamini
#
# Discover used and free IPs inside a CIDR (IPv4).
#
# Features:
#   - Enumerates all host IPs in a CIDR (excludes network & broadcast)
#   - Finds "used" IPs via nmap (preferred), fping, or ping fallback
#   - Computes free IPs = all - used
#   - Robust sorting with LC_ALL=C for comm (or awk set-diff with --no-comm)
#   - Per-run timestamped output directory including the CIDR (Option A)
#
# Usage:
#   ./cidr_used_free_ips.sh <CIDR> [--timeout-ms 700] [--out-dir ./ip-scan] [--no-comm]
#
# Examples:
#   ./cidr_used_free_ips.sh 10.237.210.0/24
#   ./cidr_used_free_ips.sh 10.237.210.0/24 --timeout-ms 1000 --out-dir /tmp/scans
#   ./cidr_used_free_ips.sh 10.237.210.0/24 --no-comm
#
# Prereqs (OL8/RHEL8):
#   sudo dnf install -y nmap
#   sudo dnf install -y oracle-epel-release-el8 && sudo dnf install -y fping
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  echo "Usage: $0 <CIDR> [--timeout-ms 700] [--out-dir ./ip-scan] [--no-comm]" >&2
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

CIDR="$1"; shift || true
TIMEOUT_MS=700
OUT_DIR="./ip-scan"
USE_COMM_DIFF=1   # 1 = use sort+comm; 0 = use awk set-diff (no sorting required)

# ---- Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout-ms)
      TIMEOUT_MS="${2:-700}"; shift 2;;
    --out-dir)
      OUT_DIR="${2:-./ip-scan}"; shift 2;;
    --no-comm)
      USE_COMM_DIFF=0; shift;;
    -h|--help)
      usage;;
    *)
      echo "Unknown arg: $1" >&2; usage;;
  esac
done

# ---- Helpers
has_cmd() { command -v "$1" >/dev/null 2>&1; }

sanitize_cidr() {
  # Replace "/" with "_" to make it safe in file/dir names
  echo "$1" | sed -E 's|/|_|g'
}

# ---- Build per-run timestamped directory
CIDR_SAFE="$(sanitize_cidr "$CIDR")"                  # e.g., "10.237.210.0_24"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"                  # e.g., "20260118_231245"
RUN_DIR="${OUT_DIR%/}/scan_${CIDR_SAFE}_${TIMESTAMP}" # e.g., "./ip-scan/scan_10.237.210.0_24_20260118_231245"
mkdir -p "$RUN_DIR"

ALL_IPS_FILE="$RUN_DIR/all_ips.txt"
USED_IPS_FILE="$RUN_DIR/used_ips.txt"
FREE_IPS_FILE="$RUN_DIR/free_ips.txt"

# ---- Step 1: Enumerate all host IPs within CIDR (exclude network & broadcast)
if has_cmd nmap; then
  # nmap -sL lists all addresses; parse IPs only
  nmap -n -sL "$CIDR" 2>/dev/null \
    | awk '/Nmap scan report/{print $NF}' \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' > "$ALL_IPS_FILE"
elif has_cmd python3; then
  # Python's ipaddress for precise host enumeration
  python3 - "$CIDR" <<'PYCODE' >"$ALL_IPS_FILE"
import sys, ipaddress
net = ipaddress.ip_network(sys.argv[1], strict=False)
for ip in net.hosts():
    print(ip)
PYCODE
else
  echo "ERROR: Need either 'nmap' or 'python3' to enumerate hosts in $CIDR." >&2
  echo "Tip (OL8): sudo dnf install -y nmap   # or: sudo dnf install -y python3" >&2
  exit 2
fi

# ---- Step 2: Detect used (alive) IPs
: > "$USED_IPS_FILE"  # create/clear

if has_cmd nmap; then
  # nmap ping sweep (no port scan). Adjust timeout per host.
  nmap -n -sn --min-parallelism 64 --host-timeout "${TIMEOUT_MS}ms" "$CIDR" -oG - 2>/dev/null \
    | awk '/Up$/{print $2}' > "$USED_IPS_FILE"
elif has_cmd fping; then
  # fping parallel sweep from the all-IP list (quiet: alive only)
  fping -a -q -f "$ALL_IPS_FILE" -t "$TIMEOUT_MS" 2>/dev/null > "$USED_IPS_FILE" || true
else
  # Fallback: ping each host; try parallel with xargs if available
  if has_cmd xargs; then
    CONC=128
    <"$ALL_IPS_FILE" xargs -P "$CONC" -I{} sh -c "ping -c1 -W $((TIMEOUT_MS/1000)) {} >/dev/null 2>&1 && echo {}" \
      | LC_ALL=C sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -u > "$USED_IPS_FILE"
  else
    while read -r ip; do
      if ping -c1 -W $((TIMEOUT_MS/1000)) "$ip" >/dev/null 2>&1; then
        echo "$ip"
      fi
    done < "$ALL_IPS_FILE" | LC_ALL=C sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -u > "$USED_IPS_FILE"
  fi
fi

# ---- Step 3: Compute free = all - used
# Normalize line endings if dos2unix is available (defensive)
if has_cmd dos2unix; then
  dos2unix "$ALL_IPS_FILE" "$USED_IPS_FILE" 2>/dev/null || true
fi

if [[ "$USE_COMM_DIFF" -eq 1 ]]; then
  # Sort both files in numeric IP order, unique, with a stable locale
  LC_ALL=C sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -u -o "$ALL_IPS_FILE" "$ALL_IPS_FILE"
  LC_ALL=C sort -t . -k1,1n -k2,2n -k3,3n -k4,4n -u -o "$USED_IPS_FILE" "$USED_IPS_FILE"
  # comm requires sorted inputs
  comm -23 "$ALL_IPS_FILE" "$USED_IPS_FILE" > "$FREE_IPS_FILE"
else
  # AWK set difference (no sorting required; preserves ALL order)
  awk 'NR==FNR { used[$0]=1; next } !($0 in used)' "$USED_IPS_FILE" "$ALL_IPS_FILE" > "$FREE_IPS_FILE"
fi

# ---- Step 4: Summary
TOTAL_ALL=$(wc -l < "$ALL_IPS_FILE" | tr -d ' ')
TOTAL_USED=$(wc -l < "$USED_IPS_FILE" | tr -d ' ')
TOTAL_FREE=$(wc -l < "$FREE_IPS_FILE" | tr -d ' ')

echo "CIDR:          $CIDR"
echo "Timestamp:     $TIMESTAMP"
echo "Timeout (ms):  $TIMEOUT_MS"
echo "Output dir:    $RUN_DIR"
echo "All hosts:     $TOTAL_ALL   -> $ALL_IPS_FILE"
echo "Used hosts:    $TOTAL_USED  -> $USED_IPS_FILE"
echo "Free hosts:    $TOTAL_FREE  -> $FREE_IPS_FILE"

# Exit non-zero if no hosts were enumerated (bad CIDR or tool failure)
if [[ "$TOTAL_ALL" -eq 0 ]]; then
  echo "WARNING: No hosts enumerated. Check CIDR or install nmap/python3." >&2
  exit 3
fi
