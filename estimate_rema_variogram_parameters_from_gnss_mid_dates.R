############################################################
# Estimate REMA variogram parameters at GNSS interpolation-date locations.
#
# Reads the POS-derived interpolation-date CSV and writes the aRange_m and
# r02_m values used by the CryoSat-2 window and subsetting steps. The exported
# table is named
# rema_variogram_params_station_midpoint.csv.
#
# Per-station map exports include:
#   - pred_abs (predicted surface, absolute if detrend_plane=TRUE)
#   - se       (standard error)
#   - corr_center (Matern correlation vs distance from center)
#   - pred_over_se (pred_abs / se)
#
# Output per station:
#   rema_station_midpoint_maps/REMA_maps_<ST>_midpoint.csv
############################################################

suppressPackageStartupMessages({
  library(data.table)
  library(lubridate)
  library(terra)
  library(fields)
  library(spam)   # needed by fields for large problems / predictSE
})

# -----------------------------
# PATHS
# -----------------------------
# Point INTERP_DATE_CSV to the POS-derived interpolation-date CSV from the
# GNSS daily-means notebook. Point REMA_TIF to the Antarctic REMA GeoTIFF.
# OUTPUT_DIR is where the variogram CSV and optional diagnostic files are saved.
OUTPUT_DIR <- "/Volumes/icefall/marquardt/results/bias_results"
INTERP_DATE_CSV <- "/Volumes/cornice/marquardt/results/gnss_daily_means_from_pos/gnss_interpolation_mid_dates_2011_2026_29_paper_stations.csv"

PAPER_STATIONS <- c(
  "GZ01", "GZ02", "GZ06", "GZ09", "GZ13", "GZ17", "GZ18",
  sprintf("LA%02d", 1:18),
  sprintf("MG%02d", 4:7)
)

REMA_TIF <- "/Volumes/icefall/marquardt/data/DEM/rema_mosaic_100m_v2.0_filled_cop30/rema_mosaic_100m_v2.0_filled_cop30_dem.tif"

# This is the filename read by cryosat2_subsetting_filter_blockmedian.ipynb.
OUT_CSV <- file.path(OUTPUT_DIR, "rema_variogram_params_station_midpoint.csv")

# Optional: dump per station variogram bins for inspection
DUMP_VARI_BINS <- TRUE
VARI_BINS_DIR  <- file.path(OUTPUT_DIR, "rema_variogram_bins_station_midpoint")

# NEW: per-station map exports
EXPORT_MAPS   <- TRUE
MAPS_DIR      <- file.path(OUTPUT_DIR, "rema_station_midpoint_maps")

# -----------------------------
# REMA sampling / fit knobs
# -----------------------------
rema_radius_m         <- 5000
sample_spacing_m      <- 400
min_points            <- 20
max_points            <- 2500
always_downsample     <- TRUE
n_downsample          <- 100
detrend_plane         <- TRUE

Covariance            <- "Matern"
smoothness            <- 1.0

# Empirical variogram settings
vgram_bins            <- 25
n_pairs_sample        <- 500000
variogram_max_frac    <- 1.5
np_min_per_bin        <- 2000
tail_frac_for_sill    <- 0.25

# Choose aRange from empirical eff_range (fallback if NA)
use_eff_range_as_aRange <- TRUE
fallback_aRange_frac    <- 0.5   # if eff_range NA, aRange = fallback_aRange_frac * rema_radius_m

# NEW: prediction grid spacing (maps)
pred_spacing_m <- 200  # adjust (e.g., 100 for finer, 250-500 for faster)

# NEW: small epsilon to avoid division-by-zero in pred/se
se_eps <- 1e-12

seed <- 1L

# -----------------------------
# Helpers
# -----------------------------
msg <- function(...) { cat(..., "\n"); flush.console() }

ensure_dir <- function(d) {
  if (!dir.exists(d)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  invisible(d)
}

empirical_variogram_pairs <- function(X, z, n_bins, n_pairs, max_dist, seed) {
  n <- nrow(X)
  if (n < 10) stop("Too few points for variogram.")
  
  set.seed(seed)
  i <- sample.int(n, n_pairs, replace = TRUE)
  j <- sample.int(n, n_pairs, replace = TRUE)
  same <- (i == j)
  if (any(same)) j[same] <- (j[same] %% n) + 1L
  
  dx <- X[i, 1] - X[j, 1]
  dy <- X[i, 2] - X[j, 2]
  h  <- sqrt(dx * dx + dy * dy)
  
  gamma <- 0.5 * (z[i] - z[j])^2
  
  breaks <- seq(0, max_dist, length.out = n_bins + 1)
  bin <- cut(h, breaks = breaks, include.lowest = TRUE, right = TRUE)
  
  tab <- tapply(gamma, bin, function(v) c(np = length(v), mean = mean(v), sd = sd(v)))
  
  mids <- 0.5 * (breaks[-1] + breaks[-length(breaks)])
  np   <- rep(0, n_bins)
  m    <- rep(NA_real_, n_bins)
  s    <- rep(NA_real_, n_bins)
  
  for (k in seq_len(n_bins)) {
    if (!is.null(tab[[k]])) {
      np[k] <- tab[[k]]["np"]
      m[k]  <- tab[[k]]["mean"]
      s[k]  <- tab[[k]]["sd"]
    }
  }
  
  data.table(
    bin = seq_len(n_bins),
    h_mid = mids,
    np = np,
    gamma = m,
    gamma_sd = s
  )
}

robust_sill_and_range <- function(vdf, np_min = 2000, tail_frac = 0.25) {
  ok <- which(!is.na(vdf$gamma) & vdf$np >= np_min)
  if (length(ok) < 5) stop("Too few reliable variogram bins.")
  
  n_ok <- length(ok)
  n_tail <- max(3, ceiling(tail_frac * n_ok))
  tail_idx <- ok[(n_ok - n_tail + 1):n_ok]
  
  sill <- median(vdf$gamma[tail_idx], na.rm = TRUE)
  
  idx90_all <- ok[which(vdf$gamma[ok] >= 0.9 * sill)]
  eff_range <- if (length(idx90_all) > 0) vdf$h_mid[idx90_all[1]] else NA_real_
  
  list(
    sill = sill,
    eff_range = eff_range,
    ok_bins = as.integer(ok),
    tail_bins = as.integer(tail_idx)
  )
}

sample_rema_patch <- function(rema, x0, y0, radius_m, sample_spacing_m) {
  if (terra::is.lonlat(rema)) stop("REMA appears lon/lat; expected projected meters.")
  
  e <- terra::ext(x0 - radius_m, x0 + radius_m, y0 - radius_m, y0 + radius_m)
  r_crop <- terra::crop(rema, e)
  
  res0 <- terra::res(r_crop)[1]
  fact <- max(1L, round(sample_spacing_m / res0))
  r_use <- if (fact > 1L) terra::aggregate(r_crop, fact = fact, fun = mean, na.rm = TRUE) else r_crop
  
  df <- as.data.frame(r_use, xy = TRUE, na.rm = TRUE)
  if (nrow(df) == 0L) stop("No REMA data in cropped extent.")
  names(df)[1:3] <- c("x", "y", "z")
  
  d2 <- (df$x - x0)^2 + (df$y - y0)^2
  df <- df[d2 <= radius_m^2, ]
  if (nrow(df) == 0L) stop("No points inside circular radius.")
  df
}

# r_p where corr(r_p)=p for Matern
corr_length_for_p <- function(p, aRange_m, smoothness, d_max = NULL) {
  if (!is.finite(p) || p <= 0 || p >= 1) stop("p must be in (0,1).")
  if (!is.finite(aRange_m) || aRange_m <= 0) stop("aRange_m must be positive.")
  if (!is.finite(smoothness) || smoothness <= 0) stop("smoothness must be positive.")
  
  if (is.null(d_max)) d_max <- 50 * aRange_m
  
  f <- function(d) fields::Matern(d, range = aRange_m, smoothness = smoothness) - p
  
  lo <- 0
  hi <- d_max
  f_hi <- f(hi)
  
  iter <- 0L
  while (f_hi > 0 && iter < 20L) {
    hi <- hi * 2
    f_hi <- f(hi)
    iter <- iter + 1L
  }
  if (f_hi > 0) return(hi)
  
  uniroot(function(d) f(d), lower = lo, upper = hi)$root
}

# Pick the middle GNSS interpolation date for each station.
pick_station_location_midpoint <- function(pos_dt, st) {
  sub <- pos_dt[station == st]
  if (nrow(sub) == 0L) return(NULL)

  date_col <- if ("mid_dt" %in% names(sub)) "mid_dt" else "mid_day"
  sub[, center_date := as.Date(substr(as.character(get(date_col)), 1L, 10L))]
  sub[, x_center := as.numeric(x_gnss)]
  sub[, y_center := as.numeric(y_gnss)]
  sub <- sub[!is.na(center_date) & is.finite(x_center) & is.finite(y_center)]
  if (nrow(sub) == 0L) return(NULL)

  setorder(sub, center_date)
  idx <- as.integer(ceiling(nrow(sub) / 2.0))
  sub <- sub[idx]

  list(
    x0 = as.numeric(sub$x_center),
    y0 = as.numeric(sub$y_center),
    mid_used = as.character(sub$center_date),
    window_id_used = "GNSS_INTERPOLATION_DATE_LIST"
  )
}

# build prediction grid in square then tag inside circle
make_pred_grid <- function(x0, y0, radius_m, spacing_m) {
  xs <- seq(x0 - radius_m, x0 + radius_m, by = spacing_m)
  ys <- seq(y0 - radius_m, y0 + radius_m, by = spacing_m)
  G  <- expand.grid(x = xs, y = ys)  # x varies fastest
  d2 <- (G$x - x0)^2 + (G$y - y0)^2
  G$inside <- d2 <= radius_m^2
  G$d      <- sqrt(d2)
  list(G = G, xs = xs, ys = ys)
}

# -----------------------------
# MAIN
# -----------------------------
if (!file.exists(INTERP_DATE_CSV)) stop("Missing GNSS interpolation-date CSV: ", INTERP_DATE_CSV)
if (!file.exists(REMA_TIF)) stop("Missing REMA tif: ", REMA_TIF)

meta <- fread(INTERP_DATE_CSV)
need_cols <- c("station", "x_gnss", "y_gnss")
if (!all(need_cols %in% names(meta)) || !any(c("mid_dt", "mid_day") %in% names(meta))) {
  stop("GNSS interpolation-date CSV must contain station, mid_dt or mid_day, x_gnss, and y_gnss.")
}
meta[, station := toupper(trimws(as.character(station)))]
meta <- meta[station %chin% PAPER_STATIONS]

ensure_dir(dirname(OUT_CSV))
if (DUMP_VARI_BINS) ensure_dir(VARI_BINS_DIR)
if (EXPORT_MAPS)   ensure_dir(MAPS_DIR)

msg("[REMA] Loading GNSS interpolation-date CSV: ", INTERP_DATE_CSV)
msg("[REMA] Loading REMA raster once...")
rema <- terra::rast(REMA_TIF)

stations <- PAPER_STATIONS
out_rows <- list()

# thresholds 0.1 ... 0.9
p_vec <- seq(0.1, 0.9, by = 0.1)

for (st in stations) {
  
  loc <- pick_station_location_midpoint(meta, st)
  if (is.null(loc)) next
  
  x0 <- loc$x0
  y0 <- loc$y0
  
  msg("--------------------------------------------------")
  msg("[REMA] station=", st, " midpoint mid=", loc$mid_used, " x0=", x0, " y0=", y0)
  
  dfp <- try(sample_rema_patch(rema, x0, y0, rema_radius_m, sample_spacing_m), silent = TRUE)
  if (inherits(dfp, "try-error")) {
    msg("[WARN] sampling failed: ", as.character(dfp))
    next
  }
  if (nrow(dfp) < min_points) {
    msg("[WARN] too few points: ", nrow(dfp))
    next
  }
  
  if (nrow(dfp) > max_points) {
    set.seed(seed)
    dfp <- dfp[sample.int(nrow(dfp), max_points), ]
  }
  if (always_downsample && nrow(dfp) > n_downsample) {
    set.seed(seed)
    dfp <- dfp[sample.int(nrow(dfp), n_downsample), ]
  }
  
  X_m <- as.matrix(dfp[, c("x", "y")])
  z_raw <- dfp$z
  z_used <- z_raw
  
  # detrend plane if requested
  plane <- NULL
  if (detrend_plane) {
    plane <- lm(z_used ~ X_m[, 1] + X_m[, 2])
    z_used <- resid(plane)
  }
  
  # empirical variogram
  vg <- try(
    empirical_variogram_pairs(
      X = X_m, z = z_used,
      n_bins = vgram_bins,
      n_pairs = n_pairs_sample,
      max_dist = variogram_max_frac * rema_radius_m,
      seed = seed
    ),
    silent = TRUE
  )
  if (inherits(vg, "try-error")) {
    msg("[WARN] variogram failed: ", as.character(vg))
    next
  }
  
  sill_info <- try(
    robust_sill_and_range(vg, np_min = np_min_per_bin, tail_frac = tail_frac_for_sill),
    silent = TRUE
  )
  if (inherits(sill_info, "try-error")) {
    msg("[WARN] sill/range failed: ", as.character(sill_info))
    next
  }
  
  aRange_m <- if (use_eff_range_as_aRange && is.finite(sill_info$eff_range)) {
    sill_info$eff_range
  } else {
    fallback_aRange_frac * rema_radius_m
  }
  
  # compute r01..r09
  r_vals <- rep(NA_real_, length(p_vec))
  for (ii in seq_along(p_vec)) {
    p <- p_vec[ii]
    rr <- try(corr_length_for_p(p = p, aRange_m = aRange_m, smoothness = smoothness), silent = TRUE)
    r_vals[ii] <- if (inherits(rr, "try-error")) NA_real_ else as.numeric(rr)
  }
  
  r_cols <- as.list(r_vals)
  names(r_cols) <- sprintf("r%02d_m", as.integer(p_vec * 10))
  
  if (DUMP_VARI_BINS) {
    bins_path <- file.path(VARI_BINS_DIR, sprintf("rema_variogram_bins_%s_midpoint.csv", toupper(st)))
    fwrite(vg, bins_path)
  }
  
  # ------------------------------------------------------------
  # NEW: Fit spatialProcess and export prediction maps
  # ------------------------------------------------------------
  if (EXPORT_MAPS) {
    
    # Build prediction grid (square), tag circle membership
    grd <- make_pred_grid(x0, y0, rema_radius_m, pred_spacing_m)
    G   <- grd$G
    Gc  <- as.matrix(G[, c("x", "y")])
    
    # correlation-to-center map (pure Matern correlation vs distance)
    corr_center <- fields::Matern(G$d, range = aRange_m, smoothness = smoothness)
    
    # Fit spatial process on residuals (z_used)
    # NOTE: This uses your chosen aRange_m and smoothness as fixed covariance settings.
    sp_obj <- try(
      fields::spatialProcess(
        x = X_m,
        y = z_used,
        Covariance = "Matern",
        aRange = aRange_m,
        smoothness = smoothness
      ),
      silent = TRUE
    )
    
    if (inherits(sp_obj, "try-error")) {
      msg("[WARN] spatialProcess fit failed: ", as.character(sp_obj))
    } else {
      # Predict residual and SE on full grid
      pred_resid <- try(predict(sp_obj, x = Gc), silent = TRUE)
      se_vec     <- try(predictSE(sp_obj, x = Gc), silent = TRUE)
      
      if (inherits(pred_resid, "try-error") || inherits(se_vec, "try-error")) {
        msg("[WARN] predict/predictSE failed for station ", st)
      } else {
        
        # Convert to absolute predicted surface if detrended
        if (detrend_plane) {
          b0 <- coef(plane)[1]
          b1 <- coef(plane)[2]
          b2 <- coef(plane)[3]
          trend_grid <- b0 + b1 * G$x + b2 * G$y
          pred_abs <- as.numeric(pred_resid) + as.numeric(trend_grid)
        } else {
          pred_abs <- as.numeric(pred_resid)
        }
        
        se_vec <- as.numeric(se_vec)
        pred_over_se <- pred_abs / pmax(se_vec, se_eps)
        
        maps_dt <- data.table(
          station = st,
          mid_used = loc$mid_used,
          window_id_used = loc$window_id_used,
          x0_m = x0,
          y0_m = y0,
          x = G$x,
          y = G$y,
          inside = as.integer(G$inside),
          d_m = G$d,
          corr_center = as.numeric(corr_center),
          pred_abs = pred_abs,
          pred_resid = as.numeric(pred_resid),
          se = se_vec,
          pred_over_se = pred_over_se
        )
        
        out_map_path <- file.path(MAPS_DIR, sprintf("REMA_maps_%s_midpoint.csv", toupper(st)))
        fwrite(maps_dt, out_map_path)
        msg("[MAPS] wrote: ", out_map_path)
      }
    }
  }
  
  # collect station variogram outputs (as before)
  out_rows[[length(out_rows) + 1L]] <- c(
    list(
      station = st,
      x0_m = x0,
      y0_m = y0,
      mid_used = loc$mid_used,
      window_id_used = loc$window_id_used,
      rema_radius_m = rema_radius_m,
      sample_spacing_m = sample_spacing_m,
      n_points_used = nrow(dfp),
      Covariance = Covariance,
      smoothness = smoothness,
      sill = sill_info$sill,
      eff_range_m = sill_info$eff_range,
      aRange_m = aRange_m,
      np_min_per_bin = np_min_per_bin,
      tail_frac_for_sill = tail_frac_for_sill,
      n_pairs_sample = n_pairs_sample,
      vgram_bins = vgram_bins,
      pred_spacing_m = pred_spacing_m,
      seed = seed
    ),
    r_cols
  )
}

out_dt <- rbindlist(out_rows, fill = TRUE)
setorder(out_dt, station)

fwrite(out_dt, OUT_CSV)

msg("==================================================")
msg("[DONE] Wrote station midpoint REMA variogram params:")
msg("  ", OUT_CSV)
msg("Rows: ", nrow(out_dt))
if (DUMP_VARI_BINS) msg("Also wrote variogram bins to: ", VARI_BINS_DIR)
if (EXPORT_MAPS)   msg("Also wrote station maps to: ", MAPS_DIR)
msg("==================================================")
