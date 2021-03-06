#' Perform joint loess normalization on two Hi-C datasets
#'
#' @export
#' @importFrom data.table as.data.table data.table := rbindlist setDF setDT setDTthreads setkey is.data.table frank
#' @import ggplot2
#' @importFrom gridExtra grid.arrange
#' @importFrom stats loess loess.control optimize p.adjust predict rnbinom rnorm runif update qnorm t.test approxfun density optim quantile
#' @import mgcv
#' @importFrom BiocParallel bpmapply bplapply bpparam register registered
#' @importFrom graphics abline legend lines par persp points smoothScatter hist
#' @importFrom methods is
#' @importFrom utils read.table write.table
#' @param hic.table hic.table or a list of hic.tables generated from
#'     the create.hic.table function.
#'     list of hic.tables generated from the create.hic.table function.
#'     If you want to perform
#'    normalization over multiple chromosomes from each cell line at
#'    once utilizing parallel computing enter a list of hic.tables and
#'    set parallel = TRUE.
#' @param degree Degree of polynomial to be used for loess. Options
#'     are 0, 1, 2. The default setting is degree = 1.
#' @param span User set span for loess. If set to NA, the span will
#'     be selected automatically using the setting of loess.criterion.
#'     Defaults to NA so that
#'     automatic span selection is performed.
#'     If you know the span, setting it manually will significantly speed
#'     up computational time.
#' @param loess.criterion Automatic span selection criterion. Can use either
#'     'gcv' for generalized cross-validation or 'aicc' for Akaike Information
#'      Criterion.
#'      Span selection uses a slightly modified version of the \code{loess.as()}
#'      function from the \code{fANCOVA} package. Defaults to 'gcv'.
#' @param Plot Logical, should the MD plot showing before/after loess
#'     normalization be output? Defaults to FALSE.
#' @param Plot.smooth Logical, defaults to TRUE indicating the MD plot
#'     will be a smooth scatter plot. Set to FALSE for a scatter plot
#'     with discrete points.
#' @param parallel Logical, set to TRUE to utilize the \code{parallel} package's
#'     parallelized computing. Only works on unix operating systems. Only useful if
#'     entering a list of hic.tables. Defauts to FALSE.
#' @param BP_param Parameters for BiocParallel. Defaults to bpparam(), see help
#'     for BiocParallel for more information
#'     \url{http://bioconductor.org/packages/release/bioc/vignettes/BiocParallel/
#'     inst/doc/Introduction_To_BiocParallel.pdf}
#'
#' @details The function takes in a hic.table or a list of hic.table objects created
#'     with the \code{create.hic.loess} function. If you wish to perform joint
#'     normalization on Hi-C data for multiple chromosomes use a list of hic.tables.
#'     The process can be parallelized using the \code{parallel}
#'     setting. The data is fist transformed into what is termed an MD plot (similar
#'     to the MA plot/Bland-Altman plot). M is the log difference log2(x/y) between
#'     the two datasets. D is the unit distance in the contact matrix. The MD plot can
#'     be visualized with the \code{Plot} option. Loess regression is then
#'     performed on the MD plot to model any biases between the two Hi-C datasets. An
#'     adjusted IF is then calculated for each dataset along with an adjusted M.
#'     See methods section of Stansfield & Dozmorov 2017 for more details. Note:
#'     if you receive the warning "In simpleLoess(y, x, w, span, degree = degree,
#'     parametric = parametric,  ... :pseudoinverse used..." it should not effect
#'     your results, however it can be avoided by manually setting the span to
#'     a larger value using the span option.
#'
#'
#' @return An updated hic.table is returned with the additional columns of adj.IF1,
#'    adj.IF2 for the respective normalized IFs, an adj.M column for the
#'    adjusted M, mc for the loess correction factor, and A for the average
#'    expression value between adj.IF1 and adj.IF2. 
#'
#' @examples
#' # Create hic.table object using included Hi-C data in sparse upper
#' # triangular matrix format
#' data("HMEC.chr22")
#' data("NHEK.chr22")
#' hic.table <- create.hic.table(HMEC.chr22, NHEK.chr22, chr= 'chr22')
#' # Plug hic.table into hic_loess()
#' result <- hic_loess(hic.table, Plot = TRUE)
#' # View result
#' result
#'
hic_loess = function(hic.table, degree = 1, span = NA, loess.criterion = 'gcv',
                     Plot = FALSE, Plot.smooth = TRUE,
                     parallel = FALSE, BP_param = bpparam()
                     ) {
  # check for correct inputs
  if (!is.na(span) & span < 0.001) {
    stop('Enter a larger value for span')
  }
  if (!is.na(span) & span > 1) {
    stop('Enter a value <= 1 for span')
  }
  # check if list or single hic.table
  if (is.data.table(hic.table)) hic.table = list(hic.table)
  # apply loess.matrix to the list of matrices
  if (parallel) hic.table = BiocParallel::bplapply(hic.table, .loess.matrix,
                                     Plot = Plot, Plot.smooth = Plot.smooth,
                                     degree = degree, span = span,
                                     loess.criterion = loess.criterion, BPPARAM = BP_param)
  else hic.table = lapply(hic.table, .loess.matrix, Plot = Plot, Plot.smooth = Plot.smooth,
                          degree = degree,
                          span = span, loess.criterion = loess.criterion)

 
  # if there is only one hic.table entered pull it out the list before returning it
  if (length(hic.table) == 1) hic.table = hic.table[[1]]
  return(hic.table)
}


# background functions for hic_loess
# loess with Automatic Smoothing Parameter Selection adjusted possible
# range of smoothing originally from fANCOVA package
.loess.as <- function(x, y, degree = 1, criterion = c("aicc", "gcv"),
                      family = c("gaussian",
                                 "symmetric"), user.span = NULL, plot = FALSE, ...) {
  criterion <- match.arg(criterion)
  family <- match.arg(family)
  x <- as.matrix(x)

  if ((ncol(x) != 1) & (ncol(x) != 2))
    stop("The predictor 'x' should be one or two dimensional!!")
  if (!is.numeric(x))
    stop("argument 'x' must be numeric!")
  if (!is.numeric(y))
    stop("argument 'y' must be numeric!")
  if (any(is.na(x)))
    stop("'x' contains missing values!")
  if (any(is.na(y)))
    stop("'y' contains missing values!")
  if (!is.null(user.span) && (length(user.span) != 1 || !is.numeric(user.span)))
    stop("argument 'user.span' must be a numerical number!")
  if (nrow(x) != length(y))
    stop("'x' and 'y' have different lengths!")
  if (length(y) < 3)
    stop("not enough observations!")

  data.bind <- data.frame(x = x, y = y)
  if (ncol(x) == 1) {
    names(data.bind) <- c("x", "y")
  } else {
    names(data.bind) <- c("x1", "x2", "y")
  }

  opt.span <- function(model, criterion = c("aicc", "gcv"), span.range = c(0.01,
                                                                           0.9)) {
    as.crit <- function(x) {
      span <- x$pars$span
      traceL <- x$trace.hat
      sigma2 <- sum(x$residuals^2)/(x$n - 1)
      aicc <- log(sigma2) + 1 + 2 * (2 * (traceL + 1))/(x$n - traceL -
                                                          2)
      gcv <- x$n * sigma2/(x$n - traceL)^2
      result <- list(span = span, aicc = aicc, gcv = gcv)
      return(result)
    }
    criterion <- match.arg(criterion)
    fn <- function(span) {
      mod <- update(model, span = span)
      as.crit(mod)[[criterion]]
    }
    result <- optimize(fn, span.range)
    return(list(span = result$minimum, criterion = result$objective))
  }

  if (ncol(x) == 1) {
    if (is.null(user.span)) {
      fit0 <- loess(y ~ x, degree = degree, family = family, data = data.bind,
                    ...)
      span1 <- opt.span(fit0, criterion = criterion)$span
    } else {
      span1 <- user.span
    }
    fit <- loess(y ~ x, degree = degree, span = span1, family = family,
                 data = data.bind, ...)
  } else {
    if (is.null(user.span)) {
      fit0 <- loess(y ~ x1 + x2, degree = degree, family = family,
                    data.bind, ...)
      span1 <- opt.span(fit0, criterion = criterion)$span
    } else {
      span1 <- user.span
    }
    fit <- loess(y ~ x1 + x2, degree = degree, span = span1, family = family,
                 data = data.bind, ...)
  }
  if (plot) {
    if (ncol(x) == 1) {
      m <- 100
      x.new <- seq(min(x), max(x), length.out = m)
      fit.new <- predict(fit, data.frame(x = x.new))
      plot(x, y, col = "lightgrey", xlab = "x", ylab = "m(x)", ...)
      lines(x.new, fit.new, lwd = 1.5, ...)
    } else {
      m <- 50
      x1 <- seq(min(data.bind$x1), max(data.bind$x1), len = m)
      x2 <- seq(min(data.bind$x2), max(data.bind$x2), len = m)
      x.new <- expand.grid(x1 = x1, x2 = x2)
      fit.new <- matrix(predict(fit, x.new), m, m)
      persp(x1, x2, fit.new, theta = 40, phi = 30, ticktype = "detailed",
            xlab = "x1", ylab = "x2", zlab = "y", col = "lightblue",
            expand = 0.6)
    }
  }
  return(fit)
}


# function to perform loess normalization on a hic.table called from
# within hic_loess main function
.loess.matrix <- function(hic.table, degree = 1, Plot = FALSE, 
                          Plot.smooth = TRUE, span = NA,
                          loess.criterion = "gcv") {
  # perform loess on data
  if (is.na(span)) {
    l <- .loess.as(x = hic.table$D, y = hic.table$M, degree = degree,
                   criterion = loess.criterion,
                   control = loess.control(surface = "interpolate",
                                           statistics = "approximate", trace.hat = "approximate"))
    # calculate gcv and AIC
    traceL <- l$trace.hat
    sigma2 <- sum(l$residuals^2)/(l$n - 1)
    aicc <- log(sigma2) + 1 + 2 * (2 * (traceL + 1))/(l$n - traceL -
                                                        2)
    gcv <- l$n * sigma2/(l$n - traceL)^2
  } else {
    l <- loess(hic.table$M ~ hic.table$D, degree = degree, span = span,
               control = loess.control(surface = "interpolate", statistics = "approximate",
                                       trace.hat = "approximate"))
    # calculate gcv and AIC
    traceL <- l$trace.hat
    sigma2 <- sum(l$residuals^2)/(l$n - 1)
    aicc <- log(sigma2) + 1 + 2 * (2 * (traceL + 1))/(l$n - traceL -
                                                        2)
    gcv <- l$n * sigma2/(l$n - traceL)^2
  }
  # print the span picked by gcv
  message("Span for loess: ", l$pars$span)
  message("GCV for loess: ", gcv)
  message("AIC for loess: ", aicc)
  # get the correction factor
  mc <- predict(l, hic.table$D)
  if (Plot) {
    MD.plot1(hic.table$M, hic.table$D, mc, smooth = Plot.smooth)
  }
  # create mhat matrix using mc/2 which will be subtracted/added to the
  # original matrices to produce the loess normalized matrices
  mhat <- mc/2
  # normalize original matrices
  if (sum(hic.table$IF1 == 0) + sum(hic.table$IF2 == 0) > 0) {
    hic.table[, `:=`(adj.IF1, 2^(log2(IF1 + 1) + mhat))]
    hic.table[, `:=`(adj.IF2, 2^(log2(IF2 + 1) - mhat))]
    hic.table[, `:=`(adj.M, log2((adj.IF2)/(adj.IF1)))]
    hic.table[, `:=`(mc, mc)]
    hic.table[, `:=`(A, (adj.IF1 + adj.IF2)/2)]
  } else {
    hic.table[, `:=`(adj.IF1, 2^(log2(IF1) + mhat))]
    hic.table[, `:=`(adj.IF2, 2^(log2(IF2) - mhat))]
    hic.table[, `:=`(adj.M, log2((adj.IF2)/(adj.IF1)))]
    hic.table[, `:=`(mc, mc)]
    hic.table[, `:=`(A, (adj.IF1 + adj.IF2)/2)]
  }
  # check for negative values in normalized matrices
  # set any negative values to 0
  if (sum(hic.table$adj.IF1 < 0, na.rm = TRUE) > 0) {
    message("negatives introduced in normalization")
    hic.table <- hic.table[adj.IF1 > 0]
  }
  if (sum(c(hic.table$adj.IF2) < 0, na.rm = TRUE) > 0) {
    message("negatives introduced in normalization")
    hic.table <- hic.table[adj.IF2 > 0]
  }
  return(hic.table)
}