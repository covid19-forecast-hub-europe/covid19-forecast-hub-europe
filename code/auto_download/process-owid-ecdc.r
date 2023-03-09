library("readr")
library("lubridate")
library("purrr")
library("dplyr")

cat("Processing ECDC/OWID data.\n")
sources <- list(ECDC = c("Cases", "Deaths"), OWID = "Hospitalizations")

cutoff_days <- 28

for (source in names(sources)) {
  source_dir <- here::here("data-truth", source)
  snapshot_dir <- file.path(source_dir, "snapshots")
  final_dir <- file.path(source_dir, "final")

  if (!dir.exists(final_dir)) dir.create(final_dir)

  file_pattern <- paste(tolower(sources[[source]]), collapse = "-")

  snapshot_files <- list.files(snapshot_dir)
  final_files <- list.files(final_dir)

  snapshot_dates <- as.Date(
    sub(
      paste0("^covid-", file_pattern, "_(.*)\\.csv"), "\\1",
      grep(paste0("^covid-", file_pattern, "_"), snapshot_files, value = TRUE)
    )
  )

  final_dates <- snapshot_dates - days(cutoff_days)
  process_final_dates <- final_dates

  if (length(final_files) > 0) {
    final_dates_present <- file.exists(
      file.path(final_dir, paste0(
        "covid-", file_pattern, "-final_", process_final_dates, ".csv"
      ))
    )
    process_final_dates <- process_final_dates[!final_dates_present]
  }

  if (length(process_final_dates) > 0) {
    if (min(process_final_dates) == min(snapshot_dates) - days(cutoff_days)) {
      ## need to create first "final" dataset
      init <- readr::read_csv(
        file.path(
          snapshot_dir, grep(min(snapshot_dates), snapshot_files, value = TRUE)
        ),
        show_col_types = FALSE
      ) |>
        dplyr::mutate(snapshot_date = min(snapshot_dates)) |>
        dplyr::filter(date <= min(snapshot_dates) - days(cutoff_days))
      readr::write_csv(init, file.path(
        final_dir, paste0(
          "covid-", file_pattern, "-final_",
          min(process_final_dates),
          ".csv"
        )
      ))
      process_final_dates <-
        process_final_dates[
          !(process_final_dates == min(snapshot_dates) - days(cutoff_days))
        ]
    }

    snapshot_dates <- snapshot_dates[
      snapshot_dates >= min(process_final_dates) + days(cutoff_days)
    ]

    ## create snapshot dataset
    snapshots <- purrr::map(
      snapshot_dates,
      \(x) readr::read_csv(
        file.path(snapshot_dir, grep(x, snapshot_files, value = TRUE)),
        show_col_types = FALSE
      ) |>
        dplyr::mutate(snapshot_date = x)
    ) |>
      dplyr::bind_rows()

    for (final_date_chr in as.character(process_final_dates)) {
      final_date <- as.Date(final_date_chr)
      previous_date <- max(final_dates[final_dates < final_date])
      init <- readr::read_csv(
        file.path(
          final_dir, paste0(
            "covid-", file_pattern, "-final_", previous_date, ".csv"
          )
        ),
        show_col_types = FALSE
      )
      df <- init |>
        dplyr::bind_rows(snapshots) |>
        dplyr::filter(
          snapshot_date <= final_date + days(cutoff_days),
          snapshot_date >= date + days(cutoff_days)
        ) |>
        dplyr::group_by(date) |>
        dplyr::filter(snapshot_date == min(snapshot_date)) |>
        dplyr::ungroup() |>
        dplyr::distinct()
      readr::write_csv(df, file.path(
        final_dir, paste0(
          "covid-", file_pattern, "-final_", final_date, ".csv"
        )
      ))
    }

    ## create master data file
    recommended_cutoffs <- readr::read_csv(
      file.path(source_dir, "recommended-cutoffs.csv"),
      show_col_types = FALSE
    )

    latest_final <- readr::read_csv(
      file.path(
        final_dir, paste0(
          "covid-", file_pattern, "-final_", max(final_dates), ".csv"
        )
      ),
      show_col_types = FALSE
    )

    latest_snapshot <- snapshots |>
      dplyr::filter(snapshot_date == max(snapshot_date))

    new_data <- latest_snapshot |>
      dplyr::anti_join(
        latest_final,
        by = c("location_name", "location", "date", "source")
      ) |>
      dplyr::left_join(recommended_cutoffs) |>
      tidyr::replace_na(list(cutoff_weeks = 0)) |>
      dplyr::group_by(location_name, location, source) |>
      dplyr::mutate(status = dplyr::if_else(
        floor(as.integer(max(date) - date) / 7) < cutoff_weeks,
        "expecting revisions", "near final"
      )) |>
      dplyr::select(-cutoff_weeks)

    status_factors <- c("final", "near final", "expecting revisions")

    df <- latest_final |>
      dplyr::mutate(status = "final") |>
      dplyr::bind_rows(new_data) |>
      dplyr::arrange(location_name, location, date)

    ## remove countries with stale data (nothing for 4 weeks)
    df <- df |>
      dplyr::group_by(location) |>
      dplyr::mutate(max_loc_snapshot = max(snapshot_date)) |>
      dplyr::ungroup() |>
      dplyr::filter(max_loc_snapshot > max(snapshot_date) - days(28)) |>
      dplyr::select(-max_loc_snapshot)

    for (variable in sources[[source]]) {
      if ("target_variable" %in% colnames(df)) {
        df <- df |>
          dplyr::filter(
            target_variable ==
              paste("inc", substr(tolower(variable), 1, nchar(variable) - 1))
          )
      }
      ## identify and shift weekly data
      df <- df |>
        EuroForecastHub::convert_to_weekly() |>
        dplyr::select(
          location_name, location, date, value, source, snapshot_date, status
        )

      readr::write_csv(
        df,
        file.path(
          source_dir, paste0("truth_", source, "-Incident ", variable, ".csv")
        )
      )

      readr::write_csv(
        df |> dplyr::filter(status != "expecting revisions"),
        file.path(
          source_dir,
          paste0("truncated_", source, "-Incident ", variable, ".csv")
        )
      )
    }
  } else {
    message(source, ": No new data to process")
  }
}
