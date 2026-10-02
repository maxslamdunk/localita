#!/bin/zsh
# Collect routing traces: seven app prompts (training) then the three
# real-generation-v1 cases (held-out test), one model process at a time.
# Usage: collect.sh <repo> <cli> <prompt-dir> <out-dir>
set -u
repo=$1 cli=$2 prompts=$3 out=$4
mkdir -p $out
run() {  # name messages-file seed max-new
  local name=$1 msgs=$2 seed=$3 maxnew=$4
  [[ -f $out/$name/done ]] && return
  rm -rf $out/$name
  TURBO_FIELDFARE_ROUTING_TRACE=$out/$name $cli --model $repo/scratch/gemma4.gturbo \
    --messages-file $msgs --max-new $maxnew --max-context 4096 \
    --temperature 0.2 --top-k 64 --top-p 0.95 --seed $seed \
    > $out/$name.stdout 2> $out/$name.stderr
  local rc=$?
  echo "$name exit=$rc $(date +%H:%M:%S)" >> $out/progress.log
  [[ $rc -eq 0 ]] && touch $out/$name/done
}
seed=20261001
for p in paris fibonacci fieldfare cosine-similarity recommendation-systems matrix-multiplication metal-matmul; do
  seed=$((seed + 1))
  run train-$p $prompts/$p.json $seed 400
done
for cs in short-explanation:20260721 medium-review:20260722 long-synthesis:20260723; do
  run test-${cs%%:*} $repo/docs/benchmark-prompts/real-generation-v1/${cs%%:*}.json ${cs##*:} 1024
done
echo "all done $(date +%H:%M:%S)" >> $out/progress.log
