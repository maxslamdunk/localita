#!/bin/zsh
# A/B smoke for the gpu-time / read-latency footers. Not a benchmark row:
# --max-new 64 instead of the protocol's 1024, Mac default slots.
SP=/private/tmp/claude-502/-Users-max-ml-projects-iphone-port-turbo-fieldfare/98eb451e-f433-44f6-8701-bbb5d0bfb576/scratchpad
WT=$SP/tf-timing
MODEL=/Users/max/ml_projects/iphone-port/turbo-fieldfare/scratch/gemma4.gturbo
MSG=$WT/docs/benchmark-prompts/real-generation-v1/short-explanation.json
OUT=$SP/smoke; mkdir -p $OUT
run() {
  local label=$1 bin=$2
  "$bin" --model $MODEL --messages-file $MSG --max-new 64 --max-context 4096 \
    --temperature 0.2 --top-k 64 --top-p 0.95 --seed 20260721 \
    > $OUT/$label.stdout 2> $OUT/$label.stderr
  echo "$label exit=$?"
}
run base1 $SP/baseline-bin/TurboFieldfareCLI
run new1  $WT/.build/release/TurboFieldfareCLI
run base2 $SP/baseline-bin/TurboFieldfareCLI
run new2  $WT/.build/release/TurboFieldfareCLI
