# ============================================================
# KRIGING FOR ALL MANUSCRIPT STATIONS
#
# - Read the filtered block-median CryoSat-2 inputs
# - Krige all available station windows for MISWIS, POCA, and SWATH
# - Write a new results CSV for this run
# ============================================================

library(data.table)
library(lubridate)
library(fields)
library(spam)
library(future)
library(future.apply)
library(progressr)


# ============================================================
# SETTINGS
# ============================================================

# POINTS_ROOT should contain station/dataset folders with STD_FILTERED
# block-median CSVs from cryosat2_subsetting_filter_blockmedian.ipynb.
# OUTPUT_DIR is where this run's kriging-results CSV is written.
POINTS_ROOT <- "/Volumes/cornice/marquardt/data/interpWindow"

OUTPUT_DIR <- "/Volumes/cornice/marquardt/results"

N_WORKERS <- 8L


STATIONS <- c(
  "GZ01", "GZ02", "GZ06", "GZ09", "GZ13", "GZ17", "GZ18",
  sprintf("LA%02d", 1:18),
  sprintf("MG%02d", 4:7)
)

DATASETS <- c(
  "MISWIS",
  "POCA",
  "SWATH"
)

FILTER_PRODUCTS <- data.table(
  filter_product = "STD_FILTERED",
  std_threshold_pct = 5
)


BLOCKMEDIAN_PARENT <- "blockmedian_by_arange"

BLOCKMEDIAN_TAG <- "0p10x"


# ============================================================
# BASIC VALIDATION
# ============================================================

if (
  length(N_WORKERS) != 1L ||
  is.na(N_WORKERS) ||
  !is.finite(N_WORKERS) ||
  N_WORKERS < 1L
) {
  
  stop(
    "N_WORKERS must be one positive integer."
  )
}


N_WORKERS <- as.integer(
  N_WORKERS
)


if (!dir.exists(POINTS_ROOT)) {
  
  stop(
    paste0(
      "POINTS_ROOT does not exist:\n",
      POINTS_ROOT
    )
  )
}




dir.create(
  OUTPUT_DIR,
  recursive = TRUE,
  showWarnings = FALSE
)


# ============================================================
# HELPERS
# ============================================================

normalize_station <- function(x) {
  
  toupper(
    trimws(
      as.character(x)
    )
  )
}


normalize_dataset <- function(x) {
  
  toupper(
    trimws(
      as.character(x)
    )
  )
}


normalize_filter <- function(x) {
  
  toupper(
    trimws(
      as.character(x)
    )
  )
}


normalize_file_path <- function(path) {
  
  normalizePath(
    path,
    winslash = "/",
    mustWork = FALSE
  )
}


parse_utc_time <- function(x) {
  
  if (inherits(x, "POSIXt")) {
    
    return(
      as.POSIXct(
        x,
        tz = "UTC"
      )
    )
  }
  
  
  x <- as.character(x)
  
  
  parsed <- suppressWarnings(
    lubridate::ymd_hms(
      x,
      tz = "UTC",
      quiet = TRUE
    )
  )
  
  
  missing <- is.na(parsed)
  
  
  if (any(missing)) {
    
    parsed_date <- suppressWarnings(
      lubridate::ymd(
        x[missing],
        tz = "UTC",
        quiet = TRUE
      )
    )
    
    
    parsed[missing] <- parsed_date
  }
  
  
  parsed
}


make_time_key <- function(x) {
  
  parsed <- parse_utc_time(
    x
  )
  
  
  output <- rep(
    NA_character_,
    length(parsed)
  )
  
  
  good <- !is.na(parsed)
  
  
  output[good] <- format(
    parsed[good],
    "%Y-%m-%dT%H:%M:%S",
    tz = "UTC"
  )
  
  
  output
}


# ============================================================
# READ COMMENTED CSV METADATA
# ============================================================

read_comment_metadata <- function(csv_path) {
  
  lines <- readLines(
    csv_path,
    n = 250L,
    warn = FALSE
  )
  
  
  comment_lines <- lines[
    grepl(
      "^\\s*#",
      lines
    )
  ]
  
  
  metadata <- list()
  
  
  for (line in comment_lines) {
    
    text <- sub(
      "^\\s*#\\s*",
      "",
      line
    )
    
    
    if (!grepl(":", text, fixed = TRUE)) {
      
      next
    }
    
    
    split_pos <- regexpr(
      ":",
      text,
      fixed = TRUE
    )
    
    
    key <- trimws(
      substr(
        text,
        1L,
        split_pos - 1L
      )
    )
    
    
    value <- trimws(
      substr(
        text,
        split_pos + 1L,
        nchar(text)
      )
    )
    
    
    if (nzchar(key)) {
      
      metadata[[key]] <- value
    }
  }
  
  
  metadata
}


metadata_value <- function(
    metadata,
    key
) {
  
  if (!key %in% names(metadata)) {
    
    return(
      NA_character_
    )
  }
  
  
  value <- metadata[[key]]
  
  
  if (
    length(value) == 0L ||
    is.null(value)
  ) {
    
    return(
      NA_character_
    )
  }
  
  
  as.character(
    value[[1L]]
  )
}


read_window_metadata <- function(csv_path) {
  
  metadata <- read_comment_metadata(
    csv_path
  )
  
  
  midpoint_raw <- metadata_value(
    metadata,
    "mid"
  )
  
  
  w0_raw <- metadata_value(
    metadata,
    "w0"
  )
  
  
  w1_raw <- metadata_value(
    metadata,
    "w1"
  )
  
  
  arange_raw <- metadata_value(
    metadata,
    "aRange_m_station"
  )
  
  
  block_m_raw <- metadata_value(
    metadata,
    "block_m"
  )
  
  
  interp_x_raw <- metadata_value(
    metadata,
    "x_mid"
  )
  
  
  interp_y_raw <- metadata_value(
    metadata,
    "y_mid"
  )
  
  
  list(
    
    time = parse_utc_time(
      midpoint_raw
    ),
    
    w0 = parse_utc_time(
      w0_raw
    ),
    
    w1 = parse_utc_time(
      w1_raw
    ),
    
    arange = suppressWarnings(
      as.numeric(
        arange_raw
      )
    ),
    
    block_m = suppressWarnings(
      as.numeric(
        block_m_raw
      )
    ),
    
    interp_x = suppressWarnings(
      as.numeric(
        interp_x_raw
      )
    ),
    
    interp_y = suppressWarnings(
      as.numeric(
        interp_y_raw
      )
    )
  )
}


find_table_header <- function(csv_path) {
  
  lines <- readLines(
    csv_path,
    n = 400L,
    warn = FALSE
  )
  
  
  non_comment <- which(
    nzchar(
      trimws(lines)
    )
    &
      !grepl(
        "^\\s*#",
        lines
      )
  )
  
  
  if (length(non_comment) == 0L) {
    
    return(
      NA_integer_
    )
  }
  
  
  non_comment[[1L]]
}


read_window_points <- function(csv_path) {
  
  header_line <- find_table_header(
    csv_path
  )
  
  
  if (is.na(header_line)) {
    
    stop(
      "Could not locate CSV table header."
    )
  }
  
  
  data.table::fread(
    csv_path,
    skip = header_line - 1L,
    showProgress = FALSE
  )
}


# ============================================================
# DATASET VALUE COLUMN
# ============================================================

get_value_column <- function(dataset) {
  
  switch(
    dataset,
    
    MISWIS = "h_r1",
    
    POCA = "elevation",
    
    SWATH = "elevation",
    
    
    stop(
      "Unknown dataset: ",
      dataset
    )
  )
}


# ============================================================
# KRIG ONE WINDOW
# ============================================================

krig_window <- function(
    points,
    value_column,
    interp_x,
    interp_y,
    fixed_arange,
    smoothness = 1.0
) {
  
  
  X <- as.matrix(
    points[
      ,
      .(
        x,
        y
      )
    ]
  )
  
  
  storage.mode(
    X
  ) <- "double"
  
  
  colnames(
    X
  ) <- c(
    "x",
    "y"
  )
  
  
  z <- as.numeric(
    points[[value_column]]
  )
  
  
  if (nrow(X) < 4L) {
    
    stop(
      "Fewer than four valid points."
    )
  }
  
  
  if (length(z) != nrow(X)) {
    
    stop(
      paste0(
        "Coordinate/value mismatch: ",
        nrow(X),
        " coordinates vs ",
        length(z),
        " values."
      )
    )
  }
  
  
  if (any(!is.finite(X))) {
    
    stop(
      "Non-finite coordinates remain."
    )
  }
  
  
  if (any(!is.finite(z))) {
    
    stop(
      "Non-finite observation values remain."
    )
  }
  
  
  if (
    length(fixed_arange) != 1L ||
    !is.finite(fixed_arange) ||
    fixed_arange <= 0
  ) {
    
    stop(
      "Invalid station aRange."
    )
  }
  
  
  if (
    length(interp_x) != 1L ||
    length(interp_y) != 1L ||
    !is.finite(interp_x) ||
    !is.finite(interp_y)
  ) {
    
    stop(
      "Invalid interpolation coordinates."
    )
  }
  
  
  fit <- fields::spatialProcess(
    X,
    z,
    smoothness = smoothness,
    aRange = fixed_arange
  )
  
  
  prediction_location <- matrix(
    c(
      interp_x,
      interp_y
    ),
    nrow = 1L,
    ncol = 2L,
    byrow = TRUE
  )
  
  
  storage.mode(
    prediction_location
  ) <- "double"
  
  
  colnames(
    prediction_location
  ) <- c(
    "x",
    "y"
  )
  
  
  krig_est <- as.numeric(
    predict(
      fit,
      prediction_location
    )
  )
  
  
  if (length(krig_est) != 1L) {
    
    stop(
      paste0(
        "Expected one prediction, got ",
        length(krig_est),
        "."
      )
    )
  }
  
  
  if (!is.finite(krig_est[[1L]])) {
    
    stop(
      "Kriging prediction is not finite."
    )
  }
  
  
  krig_est <- krig_est[[1L]]
  
  
  krig_unc <- as.numeric(
    fields::predictSE(
      fit,
      xnew = prediction_location
    )
  )
  
  
  uncertainty_length <- length(
    krig_unc
  )
  
  
  if (uncertainty_length != 1L) {
    
    stop(
      paste0(
        "Expected one uncertainty value, got ",
        uncertainty_length,
        "."
      )
    )
  }
  
  
  if (!is.finite(krig_unc[[1L]])) {
    
    stop(
      "Kriging uncertainty is not finite."
    )
  }
  
  
  if (krig_unc[[1L]] < 0) {
    
    stop(
      "Kriging uncertainty is negative."
    )
  }
  
  
  krig_unc <- krig_unc[[1L]]
  
  
  lambda_solved <- tryCatch(
    
    {
      
      as.numeric(
        fit$MLESummary["lambda"]
      )
    },
    
    error = function(e) {
      
      NA_real_
    }
  )
  
  
  if (
    length(lambda_solved) != 1L ||
    !is.finite(lambda_solved)
  ) {
    
    lambda_solved <- NA_real_
  }
  
  
  list(
    krig_est = krig_est,
    krig_unc = krig_unc,
    uncertainty_length = uncertainty_length,
    lambda = lambda_solved
  )
}


# ============================================================
# FIND filtered BLOCK-MEDIAN INPUT FILES
# ============================================================

csv_index_list <- list()

for (station in normalize_station(STATIONS)) {
  for (dataset in normalize_dataset(DATASETS)) {
    for (filter_i in seq_len(nrow(FILTER_PRODUCTS))) {

      filter_product <- FILTER_PRODUCTS[filter_i, filter_product]
      std_threshold_pct <- FILTER_PRODUCTS[filter_i, std_threshold_pct]

      search_dir <- file.path(
        POINTS_ROOT,
        station,
        dataset,
        filter_product,
        BLOCKMEDIAN_PARENT,
        BLOCKMEDIAN_TAG
      )

      if (!dir.exists(search_dir)) {
        cat("[R] Directory missing: ", search_dir, "\n", sep = "")
        next
      }

      files <- list.files(
        search_dir,
        pattern = "\\.csv$",
        full.names = TRUE,
        recursive = FALSE,
        ignore.case = TRUE
      )

      if (length(files) == 0L) {
        cat("[R] No CSVs found: ", search_dir, "\n", sep = "")
        next
      }

      csv_index_list[[length(csv_index_list) + 1L]] <- data.table(
        station = station,
        dataset = dataset,
        filter_product = filter_product,
        std_threshold_pct = as.numeric(std_threshold_pct),
        points_csv = files
      )
    }
  }
}

if (length(csv_index_list) == 0L) {
  stop(
    paste0(
      "[R] No filtered block-median CSVs found under:\n",
      POINTS_ROOT
    )
  )
}

csv_index <- data.table::rbindlist(
  csv_index_list,
  use.names = TRUE,
  fill = TRUE
)

csv_index[
  ,
  points_csv := normalizePath(
    points_csv,
    winslash = "/",
    mustWork = TRUE
  )
]

csv_index <- unique(
  csv_index,
  by = c("station", "dataset", "filter_product", "points_csv")
)

setorder(
  csv_index,
  station,
  dataset,
  filter_product,
  points_csv
)

cat("\n[R] Reading midpoint metadata from filtered block-median files...\n")

candidate_times_numeric <- vapply(
  csv_index$points_csv,
  function(path) {
    metadata <- read_window_metadata(path)
    if (length(metadata$time) != 1L || is.na(metadata$time)) {
      return(NA_real_)
    }
    as.numeric(metadata$time)
  },
  numeric(1L)
)

csv_index[
  ,
  time_candidate := as.POSIXct(
    candidate_times_numeric,
    origin = "1970-01-01",
    tz = "UTC"
  )
]

if (any(is.na(csv_index$time_candidate))) {
  print(csv_index[is.na(time_candidate)])
  stop("At least one block-median CSV has an invalid midpoint.")
}

candidate_duplicates <- csv_index[
  ,
  .N,
  by = .(station, dataset, filter_product, time_candidate)
][N > 1L]

if (nrow(candidate_duplicates) > 0L) {
  print(candidate_duplicates)
  stop(
    paste0(
      "Block-median inputs contain duplicate ",
      "station/dataset/filter/midpoint files."
    )
  )
}

new_index <- csv_index
N_CANDIDATES <- nrow(csv_index)
N_TASKS <- nrow(new_index)

cat(
  "\n========================================\n",
  "[R] FULL-RUN INPUT SUMMARY\n",
  "========================================\n",
  sep = ""
)
cat("[R] filtered block-median input files: ", N_CANDIDATES, "\n", sep = "")
cat("[R] Interpolation tasks to run: ", N_TASKS, "\n", sep = "")

if (N_TASKS > 0L) {
  cat("\n[R] Tasks by station and dataset:\n")
  print(
    new_index[
      ,
      .N,
      by = .(station, dataset)
    ][order(station, dataset)]
  )
}

flush.console()


# ============================================================
# PROCESS ONE NEW WINDOW
# ============================================================

process_one_window <- function(task) {
  
  task_id <- task$task_id
  
  station <- task$station
  
  dataset <- task$dataset
  
  filter_product <- task$filter_product
  
  std_threshold_pct <- task$std_threshold_pct
  
  csv_path <- task$points_csv
  
  n_tasks <- task$n_tasks
  
  worker_pid <- Sys.getpid()
  
  
  prefix <- paste0(
    "[worker ",
    worker_pid,
    "] ",
    station,
    " ",
    dataset,
    " ",
    filter_product,
    " (",
    task_id,
    "/",
    n_tasks,
    ")"
  )
  
  
  tryCatch(
    
    {
      
      value_column <- get_value_column(
        dataset
      )
      
      
      metadata <- read_window_metadata(
        csv_path
      )
      
      
      required_numeric_metadata <- c(
        arange = metadata$arange,
        block_m = metadata$block_m,
        interp_x = metadata$interp_x,
        interp_y = metadata$interp_y
      )
      
      
      invalid_numeric <- (
        is.na(required_numeric_metadata) |
          !is.finite(required_numeric_metadata)
      )
      
      
      if (any(invalid_numeric)) {
        
        stop(
          paste0(
            "Missing/invalid numeric metadata: ",
            paste(
              names(
                required_numeric_metadata[
                  invalid_numeric
                ]
              ),
              collapse = ", "
            )
          )
        )
      }
      
      
      if (metadata$arange <= 0) {
        
        stop(
          "aRange must be positive."
        )
      }
      
      
      if (metadata$block_m <= 0) {
        
        stop(
          "block_m must be positive."
        )
      }
      
      
      if (
        length(metadata$time) != 1L ||
        is.na(metadata$time)
      ) {
        
        stop(
          "Missing or invalid midpoint time."
        )
      }
      
      
      if (
        length(metadata$w0) != 1L ||
        is.na(metadata$w0)
      ) {
        
        stop(
          "Missing or invalid w0."
        )
      }
      
      
      if (
        length(metadata$w1) != 1L ||
        is.na(metadata$w1)
      ) {
        
        stop(
          "Missing or invalid w1."
        )
      }
      
      
      points <- read_window_points(
        csv_path
      )
      
      
      required_columns <- c(
        "x",
        "y",
        value_column
      )
      
      
      if (
        !all(
          required_columns %in%
          names(points)
        )
      ) {
        
        missing_columns <- setdiff(
          required_columns,
          names(points)
        )
        
        
        stop(
          paste0(
            "Missing point columns: ",
            paste(
              missing_columns,
              collapse = ", "
            )
          )
        )
      }
      
      
      points[
        ,
        x := suppressWarnings(
          as.numeric(x)
        )
      ]
      
      
      points[
        ,
        y := suppressWarnings(
          as.numeric(y)
        )
      ]
      
      
      points[
        ,
        (value_column) := suppressWarnings(
          as.numeric(
            get(value_column)
          )
        )
      ]
      
      
      points <- points[
        is.finite(x) &
          is.finite(y) &
          is.finite(
            get(value_column)
          )
      ]
      
      
      if (nrow(points) < 4L) {
        
        stop(
          paste0(
            "Only ",
            nrow(points),
            " valid block-median points remain."
          )
        )
      }
      
      
      krig_result <- krig_window(
        points = points,
        value_column = value_column,
        interp_x = metadata$interp_x,
        interp_y = metadata$interp_y,
        fixed_arange = metadata$arange
      )
      
      
      time_window_days <- as.numeric(
        difftime(
          metadata$w1,
          metadata$w0,
          units = "days"
        )
      )
      
      
      result_row <- data.table(
        task_id = task_id,
        worker_pid = worker_pid,
        station = station,
        dataset = dataset,
        filter_product = filter_product,
        std_threshold_pct = as.numeric(
          std_threshold_pct
        ),
        value_column = value_column,
        time = metadata$time,
        w0 = metadata$w0,
        w1 = metadata$w1,
        krig_est = krig_result$krig_est,
        krig_unc = krig_result$krig_unc,
        uncertainty_length = krig_result$uncertainty_length,
        arange = metadata$arange,
        block_m = metadata$block_m,
        block_fraction_of_arange = (
          metadata$block_m /
            metadata$arange
        ),
        lambda = krig_result$lambda,
        n_points = nrow(points),
        interp_x = metadata$interp_x,
        interp_y = metadata$interp_y,
        time_window_days = time_window_days,
        variogram = "fields_Matern"
      )
      
      
      if (nrow(result_row) != 1L) {
        
        stop(
          "Result construction did not produce exactly one row."
        )
      }
      
      
      lambda_text <- if (
        is.na(krig_result$lambda)
      ) {
        
        "NA"
        
      } else {
        
        format(
          krig_result$lambda,
          scientific = TRUE,
          digits = 6
        )
      }
      
      
      log_message <- paste0(
        prefix,
        " DONE",
        " | h=",
        sprintf(
          "%.6f",
          krig_result$krig_est
        ),
        " | unc=",
        sprintf(
          "%.8f",
          krig_result$krig_unc
        ),
        " | aRange=",
        sprintf(
          "%.2f",
          metadata$arange
        ),
        " | block=",
        sprintf(
          "%.2f",
          metadata$block_m
        ),
        " | n=",
        nrow(points),
        " | lambda=",
        lambda_text
      )
      
      
      list(
        success = TRUE,
        result = result_row,
        failure = NULL,
        message = log_message
      )
    },
    
    
    error = function(e) {
      
      failure_row <- data.table(
        task_id = task_id,
        worker_pid = worker_pid,
        station = station,
        dataset = dataset,
        filter_product = filter_product,
        std_threshold_pct = as.numeric(
          std_threshold_pct
        ),
        error_message = conditionMessage(e)
      )
      
      
      list(
        success = FALSE,
        result = NULL,
        failure = failure_row,
        message = paste0(
          prefix,
          " FAILED: ",
          conditionMessage(e)
        )
      )
    }
  )
}


# ============================================================
# RUN ALL KRIGING TASKS
# ============================================================

parallel_results <- list()

failed_results <- list()

new_results_dt <- data.table()


if (N_TASKS > 0L) {
  
  
  new_index[
    ,
    task_id := as.integer(seq_len(.N))
  ]
  
  
  task_list <- lapply(
    
    seq_len(N_TASKS),
    
    function(i) {
      
      list(
        task_id = new_index$task_id[[i]],
        station = new_index$station[[i]],
        dataset = new_index$dataset[[i]],
        filter_product = new_index$filter_product[[i]],
        std_threshold_pct = new_index$std_threshold_pct[[i]],
        points_csv = new_index$points_csv[[i]],
        n_tasks = N_TASKS
      )
    }
  )
  
  
  progressr::handlers(
    progressr::handler_debug
  )
  
  
  options(
    progressr.enable = TRUE
  )
  
  
  options(
    future.globals.maxSize = 8 * 1024^3
  )
  
  
  future::plan(
    future::multisession,
    workers = N_WORKERS
  )
  
  
  cat(
    "\n========================================\n",
    "[R] STARTING KRIGING RUN\n",
    "========================================\n",
    sep = ""
  )
  
  
  cat(
    "[R] Multisession workers started: ",
    N_WORKERS,
    "\n",
    sep = ""
  )
  
  
  cat(
    "[R] Interpolation tasks: ",
    N_TASKS,
    "\n",
    sep = ""
  )
  
  
  flush.console()
  
  
  parallel_results <- progressr::with_progress(
    
    {
      
      progress_update <- progressr::progressor(
        steps = N_TASKS
      )
      
      
      future.apply::future_lapply(
        
        X = task_list,
        
        
        FUN = function(task) {
          
          task_result <- process_one_window(
            task
          )
          
          
          progress_update(
            message = task_result$message
          )
          
          
          task_result
        },
        
        
        future.chunk.size = 1L,
        
        
        future.seed = TRUE,
        
        
        future.packages = c(
          "data.table",
          "lubridate",
          "fields",
          "spam"
        )
      )
    }
  )
  
  
  future::plan(
    future::sequential
  )
  
  
  success_flags <- vapply(
    
    parallel_results,
    
    function(x) {
      
      isTRUE(
        x$success
      )
    },
    
    logical(1L)
  )
  
  
  successful_results <- parallel_results[
    success_flags
  ]
  
  
  failed_results <- parallel_results[
    !success_flags
  ]
  
  
  if (length(successful_results) > 0L) {
    
    new_results_dt <- data.table::rbindlist(
      
      lapply(
        successful_results,
        function(x) {
          x$result
        }
      ),
      
      use.names = TRUE,
      
      fill = TRUE
    )
    
    
    new_results_dt <- data.table::as.data.table(
      new_results_dt
    )
    
    
    if (
      nrow(new_results_dt) !=
      length(successful_results)
    ) {
      
      stop(
        "Successful task count does not match new result row count."
      )
    }
    
    
    if (
      any(
        new_results_dt$uncertainty_length != 1L
      )
    ) {
      
      stop(
        paste0(
          "At least one new successful interpolation ",
          "has uncertainty_length != 1."
        )
      )
    }
  }
  
  
} else {
  
  cat(
    "\n[R] No interpolation tasks were found.\n"
  )
}


# ============================================================
# FORMAT OUTPUT DATE COLUMNS
# ============================================================

if (nrow(new_results_dt) > 0L) {
  
  new_results_dt[
    ,
    time := format(
      time,
      "%Y-%m-%dT%H:%M:%OS6Z",
      tz = "UTC"
    )
  ]
  
  
  new_results_dt[
    ,
    w0 := format(
      w0,
      "%Y-%m-%dT%H:%M:%OS6Z",
      tz = "UTC"
    )
  ]
  
  
  new_results_dt[
    ,
    w1 := format(
      w1,
      "%Y-%m-%dT%H:%M:%OS6Z",
      tz = "UTC"
    )
  ]
}


# ============================================================
# KEEP THIS RUN'S SUCCESSFUL INTERPOLATIONS
# ============================================================

if (nrow(new_results_dt) == 0L) {
  stop("No successful kriging results were produced.")
}

combined_results <- data.table::as.data.table(new_results_dt)


# ============================================================
# SORT + COLUMN ORDER
# ============================================================

setorder(
  combined_results,
  station,
  dataset,
  filter_product,
  time
)


preferred_column_order <- c(
  "task_id",
  "worker_pid",
  "station",
  "dataset",
  "filter_product",
  "std_threshold_pct",
  "value_column",
  "time",
  "w0",
  "w1",
  "krig_est",
  "krig_unc",
  "uncertainty_length",
  "arange",
  "block_m",
  "block_fraction_of_arange",
  "lambda",
  "n_points",
  "interp_x",
  "interp_y",
  "time_window_days",
  "variogram"
)


preferred_column_order <- preferred_column_order[
  preferred_column_order %in%
    names(combined_results)
]


remaining_columns <- setdiff(
  names(combined_results),
  preferred_column_order
)


setcolorder(
  combined_results,
  c(
    preferred_column_order,
    remaining_columns
  )
)


# ============================================================
# WRITE OUTPUT
# ============================================================

run_timestamp <- format(
  Sys.time(),
  "%Y%m%d_%H%M%S",
  tz = "UTC"
)


output_csv <- file.path(
  
  OUTPUT_DIR,
  
  paste0(
    "kriging_results_R_fields_",
    N_WORKERS,
    "workers_blockmedian_",
    run_timestamp,
    ".csv"
  )
)


failure_csv <- file.path(
  
  OUTPUT_DIR,
  
  paste0(
    "kriging_failures_R_fields_",
    N_WORKERS,
    "workers_blockmedian_",
    run_timestamp,
    ".csv"
  )
)


data.table::fwrite(
  combined_results,
  output_csv
)


if (length(failed_results) > 0L) {
  
  failures_dt <- data.table::rbindlist(
    
    lapply(
      failed_results,
      function(x) {
        x$failure
      }
    ),
    
    use.names = TRUE,
    
    fill = TRUE
  )
  
  
  failures_dt <- data.table::as.data.table(
    failures_dt
  )
  
  
  setorder(
    failures_dt,
    task_id
  )
  
  
  data.table::fwrite(
    failures_dt,
    failure_csv
  )
}


# ============================================================
# FINAL SUMMARY
# ============================================================

cat(
  "\n========================================\n",
  "[R] FINAL SUMMARY\n",
  "========================================\n",
  sep = ""
)

cat("[R] filtered block-median input files: ", N_CANDIDATES, "\n", sep = "")
cat("[R] Kriging tasks attempted: ", N_TASKS, "\n", sep = "")
cat("[R] Successful interpolations: ", nrow(combined_results), "\n", sep = "")
cat("[R] Failed interpolations: ", length(failed_results), "\n", sep = "")

cat("\n[R] Results by station, dataset, and filter:\n")
print(
  combined_results[
    ,
    .N,
    by = .(station, dataset, filter_product, std_threshold_pct)
  ][order(station, dataset)]
)

cat(
  "\n[R] Results written to:\n",
  output_csv,
  "\n",
  sep = ""
)

if (length(failed_results) > 0L) {
  cat(
    "[R] Failed tasks written to:\n",
    failure_csv,
    "\n",
    sep = ""
  )
}

flush.console()


# ============================================================
# LEAVE FINAL COMPLETE RESULTS AVAILABLE IN R
# ============================================================

combined_results