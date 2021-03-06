% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/dumps.R
\name{.parse_dump}
\alias{.parse_dump}
\title{Parse the Dump File into a Wikitext Tibble}
\usage{
.parse_dump(dump_filename, page_info)
}
\arguments{
\item{dump_filename}{Character scalar; the full path to a dump tempfile.}

\item{page_info}{The page_info tibble generated by
\code{\link{.find_page_info}}.}
}
\value{
A tibble of English wikitext entries.
}
\description{
Parse the Dump File into a Wikitext Tibble
}
\keyword{internal}
