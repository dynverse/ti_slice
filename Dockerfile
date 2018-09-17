FROM dynverse/dynwrap:bioc

RUN R -e 'devtools::install_github("dynverse/SLICE")'

LABEL version 0.1.2

ADD . /code

ENTRYPOINT Rscript /code/run.R
