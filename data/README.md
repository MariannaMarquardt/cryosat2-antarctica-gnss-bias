# Manuscript data files

`corrected_timeseries/` contains the cleaned corrected GNSS CSVs for the 29 paper stations.

`cryosat2_kriging_results.csv` contains filtered kriging results for the same 29 stations and MISWIS, POCA, and SWATH. IS2 and the `points_csv` source-path column are excluded.

`bias_results_all_stations_LA02_LA09_swapped.csv` is the supplied, processed bias table retained as a reference result. It is filtered to the same 29 stations and excludes IS2; its source-path columns are retained.

## Inputs for reproducing the paper figures

The figure and bias-calculation cells in `cryosat2_bias_calculations_and_figures.ipynb` use these processed inputs:

- `cryosat2_kriging_results.csv`: filtered CryoSat-2 kriging results for MISWIS, POCA, and SWATH.
- `corrected_timeseries/`: one APC-corrected GNSS daily time series for each of the 29 paper stations. The LA02/LA09 record swap is reflected in the bias calculation.

Run the notebook from the `manuscript_scripts` folder. Figure outputs and derived summaries are written under `outputs/`. These processed CSVs are enough for the bias figures; raw CryoSat-2 downloads, DEM files, and `.pos` files are only needed to rerun upstream processing.


`rings/` contains the RINGS grounded-ice shapefile and its required companion files. Figure 1 uses it for the Whillans-region grounding-line panel. `antarctica_gnss_station_coordinates.csv` provides precise coordinates for the 29 paper stations; valid observation dates come from `corrected_timeseries/`. Cartopy downloads Natural Earth basemap layers the first time the map is rendered, so an internet connection may be needed once.

`interpflow/` contains the five processed inputs for the LA02 POCA interpolation example figure in `cryosat2_bias_calculations_and_figures.ipynb`:

- `la02_poca_2011-01-25_original_satellite_subset.csv`
- `la02_poca_2011-01-25_block_median_0p10x_arange.csv`
- `la02_poca_2011-01-25_kriging_prediction_surface.csv`
- `la02_poca_2011-01-25_kriging_standard_error_surface.csv`
- `rema_antarctica_la02_poca_2011-01-25_window_clip.tif`

The full REMA mosaic is not needed for this figure. The included bias-results CSV is the expected processed result; when the notebook is run from the top, the bias calculation cell writes a fresh result under `outputs/`, and the figure cells use that generated result.
