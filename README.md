# Manuscript scripts

CryoSat-2 product names used here: **SWATH is CT-Swath, POCA is CT-LI, and MISWIS is L2.**

These are the paper-specific working copies. 

## Reproduce the manuscript figures

The review package includes the processed inputs needed by the bias and figure notebook. The full raw-data workflow is not required to reproduce those figures.

From the `manuscript_scripts` folder, create the Python environment and open the notebook:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
jupyter lab cryosat2_bias_calculations_and_figures.ipynb
```

In Jupyter, choose **Restart Kernel and Run All**. Run it with `manuscript_scripts` as the working directory so the relative `data/` paths resolve. The notebook reads the kriging results and 29 corrected GNSS time series, calculates the bias table, then generates the bias figures and the LA02 POCA interpolation example. Generated figures and intermediate tables go under `outputs/`, which is excluded from Git so it can be recreated locally.

The expected precomputed bias table is retained in `data/` for reference. The notebook uses the newly calculated bias output during a top-to-bottom run. `data/interpflow/` contains the five inputs needed for the LA02 POCA example, including a small REMA clip instead of the full mosaic.

Other notebooks and scripts document upstream data acquisition and processing. Several retain paths specific to the original analysis computer; those steps require their listed source data and path updates and are not necessary for reproducing the bundled figures.

## Workflow

1. `download_cryosat2_poca_swath_2010_2026.ipynb` downloads Antarctica POCA and SWATH point products for 2010–2026. CryoSat-2 availability begins in April 2010.
2. `EarthScopeDownload.ipynb` downloads GNSS RINEX observation files from EarthScope into the `data/GNSS/docker/<station>/<year>` layout that `DockerPreprocessing.ipynb` reads. It also requests station log text for monument descriptions; it does not download position (`.pos`) files. The manuscript copy reads its access token from the `EARTHSCOPE_TOKEN` environment variable. It is configured for the hard-coded 29 paper stations and 2010–2026.
3. `DockerPreprocessing.ipynb` copies those station/year RINEX folders into the Docker `refl_code/<year>/rinex/<station>` layout and uncompresses `.Z` files.
4. `download_csrs_ppp_positions.sh` submits the staged daily RINEX files to the Canadian Geodetic Survey's CSRS-PPP service. It is set for the 29 paper stations and 2011–2026, and saves the returned ZIP files under `<results>/<station>/<year>/pos/`. The helper `csrs_ppp_auto.py` handles each CSRS-PPP request and ZIP download; its original Canadian Geodetic Survey attribution and license notice are kept in the file.
5. `extract_csrs_ppp_pos_files.ipynb` extracts `.pos` files from those ZIPs and moves them into `refl_code/<year>/pos/<station>/`, where the daily-position notebooks can read them.
6. `RunGNSSRefl.sh` runs `rinex2snr` and `quickLook` inside the GNSS-IR Docker environment for the 29 paper stations from 2011–2026, including leap days. It expects RINEX files to already be staged and uncompressed in the Docker data directory.
7. `gnssir_snr_to_adjusted_surface_elevation.ipynb` retrieves daily GNSS-IR reflector heights, applies GNSS antenna corrections, makes correction plots, and summarizes daily reflector-height counts.
8. `average_daily_regular_gnss_positions_2011_2026.ipynb` reads processed `.pos` files and writes daily mean GNSS position and height CSVs for the 29 paper stations.
9. `gnss_pos_to_daily_means_and_interpolation_dates_2011_2026.ipynb` reads processed `.pos` files for the 29 paper stations and writes daily means plus a separate GNSS-derived interpolation-date list.
10. `estimate_rema_variogram_parameters_from_gnss_mid_dates.R` reads the GNSS interpolation-date CSV and fits the REMA variogram parameters, including `aRange_m` and `r02_m`, before CryoSat-2 windows are built. It writes `rema_variogram_params_station_midpoint.csv`.
11. `generate_cryosat2_kriging_windows_master.ipynb` uses `r02_m` to build the 90-day/30-day GNSS-centered windows and exports `kriging_windows_master.csv` plus per-window CryoSat-2 point CSVs. It uses MISWIS parquet data, daily regular-GNSS positions, and the latest dated GNSS-IR corrected time-series output (whose valid dates set each station’s time bounds).
12. `cryosat2_subsetting_filter_blockmedian.ipynb` uses `r02_m` for circular point selection, applies the per-window standard-deviation filter, and uses `aRange_m` to set the block-median size before exporting filtered inputs.
13. `krige_cryosat2_all_stations.R` kriges all available filtered block-median windows for the 29 paper stations and the MISWIS, POCA, and SWATH products. Each run writes a new results CSV.
14. `cryosat2_bias_calculations_and_figures.ipynb` calculates CryoSat-2 minus GNSS bias, produces the selected bias summaries and figures, and reports total successful comparisons.

## Local path settings for review

The processing scripts retain the paths used on the analysis computer. If running a step elsewhere, change the path constants at the top of that script to the corresponding input or output on that computer:

- `EarthScopeDownload.ipynb` and `DockerPreprocessing.ipynb`: RINEX download/staging folder and Docker `refl_code` folder. The latter should contain the year/station RINEX files and the generated `snr/` and `pos/` subfolders.
- `download_csrs_ppp_positions.sh`: update `RINEX_ROOT` to the `refl_code` folder containing the staged `rinex/<station>` folders, and `PPP_RESULTS_ROOT` to the location for the downloaded result ZIPs. Make sure `python3` can import `requests` and `requests_toolbelt`.
- `extract_csrs_ppp_pos_files.ipynb`: update `ROOT`, `SRC_ROOT`, and `DST_ROOT` to the CSRS-PPP results folder and the source and destination `refl_code` folders on that computer.
- `average_daily_regular_gnss_positions_2011_2026.ipynb` and `gnss_pos_to_daily_means_and_interpolation_dates_2011_2026.ipynb`: folders containing processed `.pos` files; the second notebook writes `gnss_interpolation_mid_dates_2011_2026_29_paper_stations.csv`.
- `estimate_rema_variogram_parameters_from_gnss_mid_dates.R`: the interpolation-date CSV above and the Antarctic REMA GeoTIFF; it writes `rema_variogram_params_station_midpoint.csv`.
- `generate_cryosat2_kriging_windows_master.ipynb`: MISWIS monthly parquet directory, processed daily `.pos` directory, the bundled `data/corrected_timeseries/` files, and an output folder for `kriging_windows_master.csv` and window point CSVs.
- `cryosat2_subsetting_filter_blockmedian.ipynb`: the master-window CSV, REMA variogram CSV, MISWIS/POCA/SWATH parquet folders, and the station/dataset output tree.
- `krige_cryosat2_all_stations.R`: the folder containing the `STD_FILTERED` block-median CSVs and the destination for the kriging-results CSV.
- `cryosat2_bias_calculations_and_figures.ipynb`: the kriging-results CSV, the bundled corrected GNSS CSV folder, and the destination for bias tables and figures.
- `download_cryosat2_poca_swath_2010_2026.ipynb`: the local destination for downloaded POCA and SWATH data.


