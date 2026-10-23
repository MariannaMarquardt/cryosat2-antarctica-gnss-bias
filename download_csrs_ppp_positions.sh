#!/usr/bin/env bash
set -euo pipefail

# Edit these paths for the computer that has the RINEX files and storage.
# RINEX files should be in: RINEX_ROOT/{year}/rinex/{station}
RINEX_ROOT="/Volumes/cornice/marquardt/data/GNSS/docker/local/refl_code"
PPP_RESULTS_ROOT="/Volumes/cornice/marquardt/data/GNSS/docker"

# CSRS-PPP account email and processing settings.
USER_NAME="marianna_marquardt@mines.edu"
PYTHON_BIN="python3"
WAIT_INTERVALS=120
MAX_WORKERS=10
YEAR_MIN=2011
YEAR_MAX=2026

# Stations used in the manuscript.
STATIONS=(
  gz01 gz02 gz06 gz09 gz13 gz17 gz18
  la01 la02 la03 la04 la05 la06 la07 la08 la09
  la10 la11 la12 la13 la14 la15 la16 la17 la18
  mg04 mg05 mg06 mg07
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSRS_PPP_AUTO="$SCRIPT_DIR/csrs_ppp_auto.py"
TIMEOUT_FAILED_LOG="$PPP_RESULTS_ROOT/_csrs_timeout_failed_files.tsv"
SKIP_IF_DONE=1
SKIP_IF_TIMEOUT_FAILED=1

log() {
  printf '%s %s\n' "$(date +'%F %T')" "$*"
}

process_station_year() {
  local station="$1"
  local year="$2"
  local station_dir="$RINEX_ROOT/$year/rinex/$station"
  local output_dir="$PPP_RESULTS_ROOT/$station/$year/pos"

  if [[ ! -d "$station_dir" ]]; then
    log "No RINEX folder for $station $year: $station_dir"
    return 0
  fi

  local rinex_files=()
  local rinex_file base stem expected_zip timeout_key temp_log rc
  while IFS= read -r rinex_file; do
    rinex_files+=("$rinex_file")
  done < <(find "$station_dir" -type f -iname '*.??d' ! -name '._*' ! -name '.DS_Store' | sort)

  if [[ ${#rinex_files[@]} -eq 0 ]]; then
    log "No daily RINEX files found for $station $year"
    return 0
  fi

  mkdir -p "$output_dir"

  local count=0
  local total=${#rinex_files[@]}
  for rinex_file in "${rinex_files[@]}"; do
    count=$((count + 1))
    base="$(basename "$rinex_file")"
    stem="${base%.*}"
    expected_zip="$output_dir/${stem}_full_output.zip"
    timeout_key="${station}|${year}|${base}|${expected_zip}"

    if [[ "$SKIP_IF_DONE" -eq 1 && -s "$expected_zip" ]]; then
      log "Skipping completed file ($count/$total): $base"
      continue
    fi

    if [[ "$SKIP_IF_TIMEOUT_FAILED" -eq 1 && -f "$TIMEOUT_FAILED_LOG" ]] && \
      grep -Fxq "$timeout_key" "$TIMEOUT_FAILED_LOG"; then
      log "Skipping previous timeout ($count/$total): $base"
      continue
    fi

    log "Submitting $station $year $base ($count/$total)"
    temp_log="$(mktemp "/tmp/csrs_${station}_${year}_${stem}_XXXXXX.log")"

    set +e
    "$PYTHON_BIN" -u "$CSRS_PPP_AUTO" \
      --user_name "$USER_NAME" \
      --lang en \
      --mode Kinematic \
      --ref ITRF \
      --epoch CURR \
      --vdatum CGVD2013 \
      --rnx "$rinex_file" \
      --results_dir "$output_dir" \
      --output_pdf lite \
      --get_max "$WAIT_INTERVALS" \
      --http_timeout 20 \
      2>&1 | tee "$temp_log"
    rc=${PIPESTATUS[0]}
    set -e

    if [[ "$rc" -eq 0 ]]; then
      rm -f "$temp_log"
      log "Finished $station $year $base"
      continue
    fi

    if grep -q 'Max number of get .* exceeded' "$temp_log"; then
      mkdir -p "$(dirname "$TIMEOUT_FAILED_LOG")"
      if [[ ! -f "$TIMEOUT_FAILED_LOG" ]] || ! grep -Fxq "$timeout_key" "$TIMEOUT_FAILED_LOG"; then
        printf '%s\n' "$timeout_key" >> "$TIMEOUT_FAILED_LOG"
      fi
      log "Recorded CSRS-PPP timeout for $base"
    fi

    rm -f "$temp_log"
    log "CSRS-PPP failed for $station $year $base (exit code $rc)"
  done
}

export -f process_station_year log
export USER_NAME PYTHON_BIN WAIT_INTERVALS RINEX_ROOT PPP_RESULTS_ROOT
export CSRS_PPP_AUTO TIMEOUT_FAILED_LOG SKIP_IF_DONE SKIP_IF_TIMEOUT_FAILED

for station in "${STATIONS[@]}"; do
  for ((year = YEAR_MIN; year <= YEAR_MAX; year++)); do
    printf '%s,%s\n' "$station" "$year"
  done
done | xargs -P "$MAX_WORKERS" -I {} bash -c '
  IFS=, read -r station year <<< "$1"
  process_station_year "$station" "$year"
' _ {}

log "All station-year jobs finished."
