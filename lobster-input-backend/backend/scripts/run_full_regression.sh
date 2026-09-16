#!/bin/bash
# 服务器全量提示词回归驱动：串行跑所有套件，汇总输出到 regression_results/。
set -uo pipefail
cd /opt/lobster-backend
PY="venv/bin/python3.12"
export PYTHONPATH=/opt/lobster-backend
OUT=regression_results
mkdir -p "$OUT"
CONC="${CONC:-8}"
STAMP=$(date +%m%d_%H%M)
SUMMARY="$OUT/summary_$STAMP.txt"

run_suite() {
  local name="$1"; shift
  echo "===== $name =====" | tee -a "$SUMMARY"
  "$PY" "$@" --concurrency "$CONC" --output "$OUT/${name}_$STAMP.jsonl" --show-failures 0 2>/dev/null \
    | grep -E "TOTAL=|^[a-z_]+:" | tee -a "$SUMMARY"
}

run_suite hints scripts/prompt_correction_hints_regression.py

run_suite zh_builtin scripts/prompt_regression.py --language zh
run_suite zh_structure scripts/prompt_regression.py --language zh \
  --cases-file tests/prompt_regression/zh/structure_cases.jsonl

for f in zh_url_identifier zh_public_correction zh_semantic_cleanup zh_numbers \
         zh_user_dict_hints zh_multilingual_mix zh_long_structure; do
  run_suite "$f" scripts/prompt_regression.py --language zh \
    --cases-file "tests/prompt_regression/special/$f.jsonl"
done

for lang in en ko ru; do
  run_suite "${lang}_existing" scripts/prompt_regression.py --language "$lang" \
    --cases-file "tests/prompt_regression/$lang/transcribe_cases.jsonl"
  run_suite "${lang}_special" scripts/prompt_regression.py --language "$lang" \
    --cases-file "tests/prompt_regression/special/${lang}_special.jsonl"
done

echo "ALL DONE $STAMP" | tee -a "$SUMMARY"
