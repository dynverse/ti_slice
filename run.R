#!/usr/local/bin/Rscript

task <- dyncli::main()

library(dplyr, warn.conflicts = FALSE)
library(purrr, warn.conflicts = FALSE)

library(SLICE, warn.conflicts = FALSE)
library(igraph, warn.conflicts = FALSE)

#   ____________________________________________________________________________
#   Load data                                                               ####

expression <- as.matrix(task$expression)
parameters <- task$parameters
groups_id <- task$priors$groups_id
features_id <- task$priors$features_id


# if k is 0, set to NULL
if (parameters$k == 0) {
  parameters$k <- NULL
}

# if groups_id is not given, fill it with 1's
if(!is.null(groups_id)) {
  cellidentity <- groups_id %>%
    slice(match(rownames(expression), cell_id)) %>%
    pull(group_id) %>%
    factor()
} else {
  cellidentity <- factor(rep(1, nrow(expression)))
}

# TIMING: done with preproc
checkpoints <- list(method_afterpreproc = as.numeric(Sys.time()))

# wrap data
sc <- SLICE::construct(
  exprmatrix = as.data.frame(t(expression)),
  cellidentity = cellidentity
)

num_genes <- ncol(expression)
km <- matrix(
  runif(num_genes * num_genes),
  ncol = num_genes,
  dimnames = list(colnames(expression), colnames(expression))
)

# calculate the entropy of individual cells
sc <- SLICE::getEntropy(sc, km = km)

# reduce expression space
sc <- SLICE::getRDS(
  sc,
  method = "pca",
  num_dim = 2,
  log.base = 2,
  do.center = TRUE,
  do.scale = FALSE,
  use.cor = TRUE,
  min.var = 0,
  min.cells = 0,
  genes.use = features_id
)

# infer entropy-directed cell lineage model
sc <- SLICE::getLineageModel(
  sc,
  model.type = parameters$model.type,
  ss.method = parameters$ss.method,
  ss.threshold = parameters$ss.threshold,
  community.method = parameters$community.method,
  cluster.method = parameters$cluster.method,
  k = parameters$k,
  k.max = parameters$k.max,
  B = parameters$B,
  k.opt.method = parameters$k.opt.method,
  do.plot = FALSE
)

# TIMING: done with method
checkpoints$method_aftermethod <- as.numeric(Sys.time())

# extract the milestone ids
lin_model <- sc@model$lineageModel
milestone_ids <- names(igraph::V(lin_model))

# extract the milestone network
milestone_network <- lin_model %>%
  igraph::as_data_frame() %>%
  rename(length = weight) %>%
  mutate(directed = FALSE)

# extract the pseudotime
pseudotime <- map_df(seq_len(nrow(milestone_network)), function(i) {
  from <- milestone_network[i, 1]
  to <- milestone_network[i, 2]
  sc_tmp <- SLICE::getTrajectories(
    sc,
    method = "pc",
    start = match(from, milestone_ids),
    end = match(to, milestone_ids),
    do.plot = FALSE,
    do.trim = FALSE
  )
  sc_tmp@transitions[[1]]$i.pseudotime %>%
    tibble::rownames_to_column("cell_id") %>%
    mutate(from = from, to = to) %>%
    select(cell_id, from, to, percentage = ptime)
})

# check whether the state of a cell is in the network's
# from or to, and get the earliest timepoint
progressions <- sc@model$cells.df %>%
  tibble::rownames_to_column("cell_id") %>%
  slice(match(rownames(expression), cell_id)) %>%
  mutate(state = paste0("slice.ss.", slice.state)) %>%
  select(cell_id, state) %>%
  right_join(pseudotime, by = "cell_id") %>%
  filter((state == from) | (state == to)) %>%
  group_by(cell_id) %>%
  arrange(percentage) %>%
  slice(1) %>%
  select(-state) %>%
  ungroup()

# collect data for visualisation
cells.df <- sc@model$cells.df
edge.df <- igraph::get.edgelist(lin_model) %>%
  as.data.frame() %>%
  mutate(
    ix = match(V1, rownames(cells.df)),
    iy = match(V2, rownames(cells.df)),
    src.x = cells.df$x[ix],
    src.y = cells.df$y[ix],
    dst.x = cells.df$x[iy],
    dst.y = cells.df$y[iy]
  )

dimred <- cells.df %>%
  tibble::rownames_to_column("cell_id") %>%
  filter(slice.realcell == 1) %>%
  tibble::column_to_rownames("cell_id") %>%
  select(x, y) %>%
  as.matrix()

dimred_milestones <- cells.df %>%
  tibble::rownames_to_column("cell_id") %>%
  filter(slice.realcell == 0) %>%
  tibble::column_to_rownames("cell_id") %>%
  select(x, y) %>%
  as.matrix()

#   ____________________________________________________________________________
#   Save output                                                             ####

output <- dynwrap::wrap_data(cell_ids = rownames(dimred)) %>%
  dynwrap::add_trajectory(
    milestone_network = milestone_network,
    progressions = progressions
  ) %>%
  dynwrap::add_dimred(
    dimred = dimred
    # dimred_milestones = dimred_milestones,
    # dimred_trajectory_segments = edge.df[,c("src.x", "src.y", "dst.x", "dst.y")] %>%
    # mutate_all(as.numeric) %>%
      # as.matrix %>%
      # magrittr::set_colnames(c("from_comp_1", "from_comp_2", "to_comp_1", "to_comp_2"))
  ) %>%
  dynwrap::add_timings(checkpoints)

output %>% dyncli::write_output(task$output)
