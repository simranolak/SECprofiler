#' Detect subgroups within a window. This is a helper function and should 
#' be called by `findComplexFeatures`.
#'
#' @param tracemat A matrix of intensity values where chromatograms of
#'        individual proteins are given by the rows.
#' @param corr.cutoff The correlation value for chromatograms above which
#'        proteins are considered to be coeluting.
#' @return A vector of the same length as the number of proteins. Each element
#'         corresponds to a integer-based cluster label.
findComplexFeaturesWithinWindow <- function(tracemat, corr.cutoff,
                                            with.plot=F, sec=NULL) {
    # In case there are only two proteins in the matrix no clustering
    # is performed.
    if (nrow(tracemat) == 2) {
        corr <- proxy::simil(tracemat, method='correlation')[1]
        if (corr > corr.cutoff) {
            group.assignment <- c(1, 1)
        } else {
            group.assignment <- c(1, 2)
        }
        return(group.assignment)
    }
    # Compute distance between chromatograms as measured by the pearson
    # correlation.
    distance <- proxy::dist(tracemat, method='correlation')
    # Cluster correlation vectors hierarchically s.t. proteins that correlate
    # well with a similar group of other proteins cluster together.
    cl <- hclust(distance)
    if (with.plot) {
        plot(cl)
        abline(h=1 - corr.cutoff, col='red')
    }
    # Cut the dendrogram at specified distance.
    # For example, if the requested correlation cutoff `corr.cutoff` is
    # 0.7 then the height where the tree is cut is at 1-0.7=0.3.
    # This process will result in a vector of group labels.
    group.assignments <- cutree(cl, h=1 - corr.cutoff)
    group.found <-
        length(unique(group.assignments)) < length(group.assignments)
    group.assignments
}

#' Detect subgroups of proteins within a matrix of protein intensity traces by
#' sliding a window across the SEC dimension. Within each window proteins
#' with traces that correlate well are clustered together.
#'
#' @param trace.mat A numeric matrix where rows correspond to the different
#'        traces.
#' @param protein.names A vector with protein identifiers. This vector has to
#'        have the same length as the number of rows in `trace.mat`.
#' @param corr.cutoff The correlation value for chromatograms above which
#'        proteins are considered to be coeluting.
#' @param window.size Size of the window. Numeric.
#' @param noise.quantile The quantile to use in estimating the noise level.
#'        Intensity values that are zero are imputed with random noise
#'        according to the noise estimation.
#' @param min.sec The lowest SEC number in the sample.
#' @return An instance of class `complexFeaturesSW`.
#' @export
findComplexFeatures <- function(trace.mat,
                                protein.names,
                                corr.cutoff=0.75,
                                window.size=15,
                                with.plot=F,
                                noise.quantile=0.2,
                                min.sec=1) {
    if (!any(class(trace.mat) == 'matrix')) {
        trace.mat <- as.matrix(trace.mat)
    }
    if (nrow(trace.mat) < 2) {
        stop('Trace matrix needs at least 2 proteins')
    }
    # Impute noise for missing intensity measurements
    measure.vals <- trace.mat[trace.mat != 0]
    n.zero.entries <- sum(trace.mat == 0)
    noise.mean <- quantile(measure.vals, noise.quantile)
    noise.sd <- sd(measure.vals[measure.vals < noise.mean])
    trace.mat[trace.mat == 0] <- abs(rnorm(n.zero.entries, mean=noise.mean,
                                     sd=noise.sd))
    # Where to stop the sliding window
    end.idx <- ncol(trace.mat) - window.size

    # Analyze each window for groups of protein chromatograms that correlate
    # well. This will produce a matrix with nrows == number of proteins and 
    # ncols == number SEC positions. Each column j is a vector indicating the 
    # clustering of proteins. For example, if column j equaled c(1, 2, 2),
    # the second and third protein would form a cluster and the first protein
    # would be in its own cluster.
    groups.by.window <- sapply(seq(1, ncol(trace.mat)), function(i) {
        start.window.idx <- min(end.idx, i)
        end.window.idx <- start.window.idx + window.size
        window.trace.mat <- trace.mat[, start.window.idx:end.window.idx]
        groups.within.window <-
            findComplexFeaturesWithinWindow(window.trace.mat,
                                            corr.cutoff=corr.cutoff,
                                            with.plot=with.plot,
                                            sec=start.window.idx)

        groups.within.window
    })

    # Check for each SEC position if there is at least one subgroup above the
    # cutoff, i.e. there exists a grouping vector that has at least two 
    # numbers that are equal.
    any.subgroups.in.window <-
        apply(groups.by.window, 2, function(col) any(col != 1:length(col)))

    # For each SEC position produce a list of present clusters. Clusters are
    # represented by a vector of protein identifiers. This is therefore a list
    # of lists containing character vectors.
    groups.by.window <- apply(groups.by.window, 2, function(col) {
        lapply(unique(col), function(g) {
            protein.names[g == col]
        })
    })

    groups.dt.list <- lapply(1:length(groups.by.window), function(i) {
        # A list of string vectors, each vector represents a cluster.
        subgroups <- groups.by.window[[i]]
        subgroup.sizes <- sapply(subgroups, function(grp) length(grp))
        # Produce a list of data.tables, each DT describes a subgroup in long list
        # format.
        subgroups.dt.list <- lapply(subgroups, function(grp) {
            if (length(grp) > 1) {
                rt.dt <- data.table(sec=i, protein_id=grp,
                                    n_subunits=length(grp),
                                    subgroup=paste(grp, collapse=';'))
                # We want to report a feature RT for each position _within_ the
                # window, where the correlation was high enough. So for example
                # if the window at RT == 20 found some subgroup, then the
                # subgroup should be reported for the interval
                # [20, 20 + window.size].
                # To achieve this, we replicate the data.table and each time
                # change the RT value.
                do.call(rbind, lapply(seq(i, min(i + window.size, ncol(trace.mat))),
                   function(t) {
                       new.rt.dt <- rt.dt
                       new.rt.dt$sec <- t + (min.sec - 1)
                       new.rt.dt
                   }))
            } else {
                data.table(sec=integer(length=0), protein_id=character(0),
                           n_subunits=integer(length=0), subgroup=character(0))
            }
        })
        do.call(rbind, subgroups.dt.list)
    })
    groups.dt <- do.call(rbind, groups.dt.list)

    if (nrow(groups.dt) > 0) {
        groups.only <- subset(groups.dt, select=-protein_id)
        setkey(groups.only)
        groups.only <- unique(groups.only)
        groups.only$is_present <- T
        groups.only.wide <-
            cast(groups.only, subgroup ~ sec, value='is_present', fill=F)
        groups.mat <- as.matrix(subset(groups.only.wide, select=-subgroup))
        groups.feats <- findFeatureBoundaries(groups.mat, groups.only.wide$subgroup)
    } else {
        groups.only.wide <- data.frame()
        groups.feats <- data.frame()
    }

    result <- list(subgroups.dt=groups.dt,
                   subgroup.feats=groups.feats,
                   subgroups.wide=groups.only.wide,
                   window.size=window.size,
                   corr.cutoff=corr.cutoff)
    class(result) <- 'complexFeaturesSW'
    result
}

# trsubs <- subset(protein.traces, select=-protein_id)[1:10]
# trsubs.names <- protein.traces$protein_id[1:10]
# res = findComplexFeatures(trsubs, trsubs.names, corr.cutoff=0.99)

findFeatureBoundaries <- function(m, subgroup.names) {
    boundaries <- lapply(1:nrow(m), function(i) {
        borders <- integer(length=0)
        in.feature <- FALSE
        for (j in 1:ncol(m)) {
            if (m[i, j] && !in.feature && j != ncol(m)) {
                if (m[i, j + 1]) {
                    borders <- c(borders, j)
                    in.feature <- TRUE
                }
            }
            if (!m[i, j] && in.feature) {
                borders <- c(borders, j - 1)
                in.feature <- FALSE
            }
            if (m[i, j] && in.feature && j == ncol(m)) {
                borders <- c(borders, j)
            }
        }
        if (length(borders) > 0) {
            boundaries.m <- matrix(borders, nrow=2)
            left.boundaries <- boundaries.m[1, ]
            right.boundaries <- boundaries.m[2, ]
            data.frame(subgroup=subgroup.names[i],
                       left_sec=left.boundaries,
                       right_sec=right.boundaries)
        } else {
            data.frame()
        }
    })
    do.call(rbind, boundaries)
}