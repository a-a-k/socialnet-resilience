#!/usr/bin/env bash
set -euo pipefail; cd DeathStarBench/socialNetwork
N=${1:-50} 

mkdir -p results
touch results/chaos_runs.json

for r in $(seq 1 "$N"); do
  echo "▶️  chaos round $r / $N"

  ids=$(docker ps --filter "name=socialnetwork" -q |
        awk 'BEGIN{srand()} {if (rand()<0.3) print $0}')
        
  if [ -n "$ids" ]; then docker kill $ids || true; fi

  echo "workload..."
  wrk -t2 -c32 -d30s -R300 \
  -s wrk2/scripts/social-network/mixed-workload.lua \
  http://localhost:8080/index.html > wrk1.log 2>&1

  echo "workload done"
  echo "gathering data..."
  errors=$(grep -Eo 'Non-2xx or 3xx responses:[[:space:]]*[0-9]+' wrk1.log |
           awk '{print $NF}' || echo 0)
  total=$(grep -Eo '[0-9]+ requests in' wrk1.log |
          awk '{print $1}' || echo 0)

  echo "resulting json..."
  jq -n --argjson t "$total" --argjson e "$errors" --argjson n "$r" \
        '{round:$n,total:$t,errors:$e}' \
        >> results/chaos_runs.json

  echo "done, restarting services..."
  docker compose restart $(docker compose config --services)
  sleep 60
done
      
echo "✅ chaos_norepl done"
