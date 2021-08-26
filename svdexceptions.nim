type
  SVDError* = object of CatchableError ## \
    ## Raised when SVD file does not meet the SVD spec

  NotImplementedError* = object of CatchableError ## \
    ## Raised when a feature of the SVD spec is not implemened by this program