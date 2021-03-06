# For now, we aren't going to test *any* of this. I test it manually.

# nocov start

#' Process the Latest Wiktionary Dump File
#'
#' Using this package can result in a lot of hits to the wiktionary API. To
#' reduce that burden, this function downloads and processes the entire
#' wiktionary dump, to create a local version of the English words from the
#' latest dump.
#'
#' This function requires a lot of RAM and is very slow.
#'
#' @inheritParams wikimorphemes_cache_dir
#'
#' @return The latest dump date, invisibly.
#' @keywords internal
.process_wiktionary_dump <- function(cache_dir = wikimorphemes_cache_dir()) {
  cache_dir <- wikimorphemes_cache_dir(cache_dir)
  cache_dir <- .validate_cache_dir_write(cache_dir)

  # I'm going to need the dump date whether or not they already have a cache.
  dump_date <- .get_latest_dump_date()

  # Check if they already have a cache.
  cache_filename <- fs::path(
    cache_dir,
    "wikitext_en",
    ext = "rds"
  )

  if (.cache_up_to_date(cache_filename, dump_date)) {
    rlang::inform(
      "The existing cache is already up to date.",
      class = "no_new_dump"
    )
    return(invisible(dump_date))
  }

  # If they made it here, download the dump to a temp file.
  cat("\nDownloading latest wiktionary dump.\n")
  dump_filename <- .download_latest_dump()

  # This is slow, but gets us the info to allow us to logically go through the
  # dump. MIGHT be an issue on systems with less RAM than mine, needs to be
  # tested.
  cat("\nParsing page info.\n")
  page_info <- .find_page_info(dump_filename)

  cat("\nParsing wikitext_en.\n")
  wikitext_en <- .parse_dump(dump_filename, page_info)
  attr(wikitext_en, "wt_update_date") <- dump_date

  saveRDS(wikitext_en, cache_filename)
  return(invisible(dump_date))
}

#' Make Sure a Cache Dir is Writable
#'
#' @inheritParams wikimorphemes_cache_dir
#'
#' @return The cache_dir, if it is writable.
#' @keywords internal
.validate_cache_dir_write <- function(cache_dir) {
  # Check that they have read/write on the cache path. I don't validate the path
  # otherwise since I export the function that does so.
  if (file.access(cache_dir, 3) != 0) {
    rlang::abort(
      message = paste("You do not have write access to", dir),
      class = "dir_write_error"
    )
  }
  return(cache_dir)
}

#' Check wiktionary for the Date of the Latest Dump
#'
#' @return The dump date as a POSIXct object, in GMT.
#' @keywords internal
.get_latest_dump_date <- function() {
  return(
    lubridate::parse_date_time(
      xml2::xml_text(
        xml2::xml_find_all(
          xml2::read_xml(
            paste0(
              "https://dumps.wikimedia.org/enwiktionary/latest/",
              "enwiktionary-latest-pages-articles.xml.bz2-rss.xml"
            )
          ),
          ".//pubDate"
        )
      ),
      "a, d b Y H:M:S",
      tz = "GMT"
    )
  )
}

#' Check if the Cache is Up to Date
#'
#' @param cache_filename Character scalar; the full path to the (possible)
#'   cache.
#' @param dump_date POSIXct scalar; the date against which the cache should be
#'   compared.
#'
#' @return Logical scalar indicating whether the cache exists and is at least as
#'   new as the latest dump.
#' @keywords internal
.cache_up_to_date <- function(cache_filename, dump_date) {
  if (file.exists(cache_filename)) {
    # Check the date on the existing cache.
    wikitext_en <- readRDS(cache_filename)
    wt_update_date <- attr(wikitext_en, "wt_update_date")

    return(
      !is.null(wt_update_date) && dump_date <= wt_update_date
    )
  } else {
    return(FALSE)
  }
}

#' Download the Latest Wiktionary Dump
#'
#' @return The path to the dump tempfile.
#' @keywords internal
.download_latest_dump <- function() {
  dump_filename <- tempfile("wiktionary_dump", fileext = ".xml.bz2")
  download_check <- utils::download.file(
    url = paste0(
      "https://dumps.wikimedia.org/enwiktionary/latest/",
      "enwiktionary-latest-pages-articles.xml.bz2"
    ),
    destfile = dump_filename,
    quiet = TRUE
  )
  if (download_check == 0) {
    return(dump_filename)
  } else {
    # download.file SHOULD error but in case it errors silently do this.
    rlang::abort(
      message = paste(
        "Download failed with download.file error code",
        download_check
      ),
      class = "download_error"
    )
  }
}

#' Create a Tibble of Page Info
#'
#' @param dump_filename Character scalar; the full path to a dump tempfile.
#'
#' @return A tibble of rows with \code{<page>} tags, and information about the
#'   spacing between them.
#' @keywords internal
.find_page_info <- function(dump_filename) {
  return(
    dplyr::mutate(
      tibble::tibble(
        start_line = grep("<page>", readLines(dump_filename))
      ),
      end_line = dplyr::lead(.data$start_line - 1L),
      total_lines = .data$end_line - .data$start_line + 1L
    )
  )
}

#' Parse the Dump File into a Wikitext Tibble
#'
#' @inheritParams .find_page_info
#' @param page_info The page_info tibble generated by
#'   \code{\link{.find_page_info}}.
#'
#' @return A tibble of English wikitext entries.
#' @keywords internal
.parse_dump <- function(dump_filename, page_info) {
  # Open a connec/tion. We'll continuously read from this until we reach the
  # end, parsing as we go.
  con <- file(dump_filename, open = "r")
  on.exit(close(con), add = TRUE)

  # There will often be gaps (at least at the start). It's useful to keep track
  # of what line we're on so we can read in the gaps.
  lines_loaded <- 0L

  total_rows <- nrow(page_info)
  word_info <- vector(mode = "list", length = total_rows)

  # Now read page, which we can do simply by reading the number of lines in each
  # total_lines entry. This should be a for loop because we need each one to
  # read after the previous one, so the connection advances.
  for (i in seq_along(page_info$total_lines)) {
    if (i %% 10000 == 0) {
      cat(
        "Working on row",
        i,
        "of",
        total_rows,
        "\n"
      )
    }
    next_line <- page_info$start_line[[i]]

    # There will be garbage at the start. Jump forward.
    skip_lines <- next_line - lines_loaded - 1L

    if (skip_lines > 0) {
      throwaway <- readLines(con, skip_lines)
      lines_loaded <- lines_loaded + skip_lines
    }

    n_lines <- page_info$total_lines[[i]]

    # The last page doesn't have n_lines, so deal with that.
    this_page_vector <- if (is.na(n_lines)) {
      readLines(con, encoding = "UTF-8")
    } else {
      readLines(con, n_lines, encoding = "UTF-8")
    }

    lines_loaded <- lines_loaded + length(this_page_vector)

    # For the xml to be readable, we need to end with "</page>".
    last_page <- grep("</page>", this_page_vector)

    # If there isn't a last_page we can't deal with this.
    if (length(last_page)) {
      this_page <- paste(this_page_vector[1:last_page], collapse = "\n")

      # Check if this is an article or something else.
      this_xml <- xml2::read_xml(this_page)
      ns <- xml2::xml_text(
        xml2::xml_find_first(
          this_xml,
          ".//ns"
        )
      )

      # ns 0 is an actual article.
      if (ns == 0L) {
        this_entry <- .extract_relevant_english_wt(this_page)
        if (length(this_entry)) {
          title <- xml2::xml_text(
            xml2::xml_find_first(
              this_xml,
              ".//title"
            )
          )
          sha1 <- xml2::xml_text(
            xml2::xml_find_first(
              this_xml,
              ".//sha1"
            )
          )
          word_info[[i]] <- data.frame(
            row_n = i,
            word = title,
            wikitext = this_entry,
            sha1 = sha1
          )
        }
      }
    }
  }

  return(
    dplyr::as_tibble(
      dplyr::bind_rows(word_info)
    )
  )
}

# nocov end
