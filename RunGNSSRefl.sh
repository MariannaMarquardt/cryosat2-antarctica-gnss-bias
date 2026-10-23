#!/bin/bash

# Base directory inside the Docker container
BASE_DIR="/etc/gnssrefl/refl_code"

# Paper stations (lowercase, as expected by gnssrefl)
STATIONS=(gz01 gz02 gz06 gz09 gz13 gz17 gz18 la01 la02 la03 la04 la05 la06 la07 la08 la09 la10 la11 la12 la13 la14 la15 la16 la17 la18 mg04 mg05 mg06 mg07)

# Loop over each station
for STATION in "${STATIONS[@]}"; do
    echo "Processing station: $STATION"

    # Loop over the paper period
    for year in {2011..2026}; do
        # Get the last two digits of the year for the file extension
        year_suffix="${year: -2}"

        # Include day 366 in leap years.
        if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
            last_day=366
        else
            last_day=365
        fi

        for ((i = 1; i <= last_day; i++)); do
            # Format the day number to a three-digit string (e.g., 001, 002, ..., 365 or 366)
            day=$(printf "%03d" "$i")

            # Define the input RINEX file path
            rinex_file="${BASE_DIR}/${year}/rinex/${STATION}/${STATION}${day}0.${year_suffix}d"

            # Define the output SNR file path
            snr_file="${BASE_DIR}/${year}/snr/${STATION}/${STATION}${day}${year_suffix}.snr"

            # Skip processing if the SNR file already exists
            if [ -f "$snr_file" ]; then
                echo "SNR file $snr_file already exists. Skipping..."
                continue
            fi

            # Check if the RINEX file exists
            if [ -f "$rinex_file" ]; then
                echo "Processing $rinex_file for station $STATION, year $year, day $day..."

                # Convert the RINEX file to an SNR file
                rinex2snr "$STATION" "$year" "$day"

                # Generate a quick look or visualization
                quickLook "$STATION" "$year" "$day"
            else
                echo "RINEX file $rinex_file not found for station $STATION, year $year, day $day. Skipping..."
            fi
        done
    done
done
