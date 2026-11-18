#!/usr/bin/env bash
# Benchmarks (needs Docker + Node): throughput vs nginx, and a slow-backend test vs nginx.
# Usage: bench/run.sh [repetitions] [seconds_per_run]      (default 5 repetitions, 10 s)
#
# Method, so the numbers can be trusted:
#  - every run is repeated; the summary shows the median and the min-max range
#  - repetitions are interleaved (A B C, A B C, ...) so slow drift cannot favour one setup
#  - nginx and crystal-proxy are restarted before EVERY run (no leftover TIME_WAIT sockets, cold pools)
#  - for the throughput test we count the TCP connections the proxy opened to the backends,
#    which shows whether a setup reuses connections or churns them
set -euo pipefail
cd "$(dirname "$0")"
REPS="${1:-5}"
DURATION="${2:-10}"
rm -rf results
mkdir -p results/tp results/slow

docker compose up -d --build
sleep 6

accepts() { # total connections accepted so far by backend1 + backend2 (nginx stub_status)
  local total=0 n b
  for b in backend1 backend2; do
    n=$(docker compose exec -T "$b" wget -qO- http://127.0.0.1:81/stub | awk '/server accepts/{getline; print $1}')
    total=$((total + n))
  done
  echo "$total"
}

run() { # scenario name url connections rep
  local scenario="$1" name="$2" url="$3" conns="$4" rep="$5"
  local base="results/$scenario/${name}_c${conns}_r${rep}"
  docker compose restart -t 2 nginx crystal-proxy >/dev/null
  sleep 3
  local before=0 after=0
  [ "$scenario" = tp ] && before=$(accepts)
  docker compose exec -T load oha -z "${DURATION}s" -c "$conns" --no-tui --output-format json "$url" >"$base.json"
  [ "$scenario" = tp ] && after=$(accepts)
  echo $((after - before)) >"$base.accepts"
  echo "  done $scenario $name c=$conns rep=$rep"
}

for rep in $(seq 1 "$REPS"); do
  echo "##### repetition $rep / $REPS"
  for conns in 100 1000; do
    run tp direct          http://backend1:80/         "$conns" "$rep"
    run tp nginx_ka64      http://nginx:8081/          "$conns" "$rep"
    run tp nginx_ka1024    http://nginx:8088/          "$conns" "$rep"
    run tp crystal_idle256 http://crystal-proxy:8082/  "$conns" "$rep"
    run tp crystal_idle1024 http://crystal-proxy:8090/ "$conns" "$rep"
  done
  # one backend is slow (+500 ms), 50 connections
  run slow direct_fast              http://fast:80/            50 "$rep"
  run slow nginx_default            http://nginx:8085/         50 "$rep"
  run slow nginx_timeout            http://nginx:8086/         50 "$rep"
  run slow nginx_timeout_nomaxfails http://nginx:8089/         50 "$rep"
  run slow crystal_plain            http://crystal-proxy:8083/ 50 "$rep"
done

docker compose down
node summarize.mjs | tee results/summary.md
