#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Utility functions to deserialize objects from Java.

# nolint start
# Type mapping from Java to R
#
# void -> NULL
# Int -> integer
# String -> character
# Boolean -> logical
# Float -> double
# Double -> double
# Long -> double
# Array[Byte] -> raw
# Date -> Date
# Time -> POSIXct
#
# Array[T] -> list()
# Object -> jobj
#
# nolint end

readObject <- function(con) {
  # Read type first
  type <- readType(con)
  readTypedObject(con, type)
}

readTypedObject <- function(con, type) {
  switch(type,
    "i" = readInt(con),
    "c" = readString(con),
    "b" = readBoolean(con),
    "d" = readDouble(con),
    "r" = readRaw(con),
    "D" = readDate(con),
    "t" = readTime(con),
    "a" = readArray(con),
    "l" = readList(con),
    "e" = readEnv(con),
    "s" = readStruct(con),
    "n" = NULL,
    "j" = getJobj(readString(con)),
    stop(paste("Unsupported type for deserialization", type)))
}

readStringData <- function(con, len) {
  raw <- readBin(con, raw(), len, endian = "big")
  string <- rawToChar(raw)
  Encoding(string) <- "UTF-8"
  string
}

readString <- function(con) {
  stringLen <- readInt(con)
  readStringData(con, stringLen)
}

readInt <- function(con) {
  readBin(con, integer(), n = 1, endian = "big")
}

readDouble <- function(con) {
  readBin(con, double(), n = 1, endian = "big")
}

readBoolean <- function(con) {
  as.logical(readInt(con))
}

readType <- function(con) {
  rawToChar(readBin(con, "raw", n = 1L))
}

readDate <- function(con) {
  as.Date(readString(con))
}

readTime <- function(con) {
  t <- readDouble(con)
  as.POSIXct(t, origin = "1970-01-01")
}

readArray <- function(con) {
  type <- readType(con)
  len <- readInt(con)
  if (len > 0) {
    l <- vector("list", len)
    for (i in 1:len) {
      l[[i]] <- readTypedObject(con, type)
    }
    l
  } else {
    list()
  }
}

# Read a list. Types of each element may be different.
# Null objects are read as NA.
readList <- function(con) {
  len <- readInt(con)
  if (len > 0) {
    l <- vector("list", len)
    for (i in 1:len) {
      elem <- readObject(con)
      if (is.null(elem)) {
        elem <- NA
      }
      l[[i]] <- elem
    }
    l
  } else {
    list()
  }
}

readEnv <- function(con) {
  env <- new.env()
  len <- readInt(con)
  if (len > 0) {
    for (i in 1:len) {
      key <- readString(con)
      value <- readObject(con)
      env[[key]] <- value
    }
  }
  env
}

# Read a field of StructType from SparkDataFrame
# into a named list in R whose class is "struct"
readStruct <- function(con) {
  names <- readObject(con)
  fields <- readObject(con)
  names(fields) <- names
  listToStruct(fields)
}

readRaw <- function(con) {
  dataLen <- readInt(con)
  readBin(con, raw(), as.integer(dataLen), endian = "big")
}

readRawLen <- function(con, dataLen) {
  readBin(con, raw(), as.integer(dataLen), endian = "big")
}

readDeserialize <- function(con) {
  # We have two cases that are possible - In one, the entire partition is
  # encoded as a byte array, so we have only one value to read. If so just
  # return firstData
  dataLen <- readInt(con)
  firstData <- unserialize(
      readBin(con, raw(), as.integer(dataLen), endian = "big"))

  # Else, read things into a list
  dataLen <- readInt(con)
  if (length(dataLen) > 0 && dataLen > 0) {
    data <- list(firstData)
    while (length(dataLen) > 0 && dataLen > 0) {
      data[[length(data) + 1L]] <- unserialize(
          readBin(con, raw(), as.integer(dataLen), endian = "big"))
      dataLen <- readInt(con)
    }
    unlist(data, recursive = FALSE)
  } else {
    firstData
  }
}

readMultipleObjects <- function(inputCon) {
  # readMultipleObjects will read multiple continuous objects from
  # a DataOutputStream. There is no preceding field telling the count
  # of the objects, so the number of objects varies, we try to read
  # all objects in a loop until the end of the stream.
  data <- list()
  while (TRUE) {
    # If reaching the end of the stream, type returned should be "".
    type <- readType(inputCon)
    if (type == "") {
      break
    }
    data[[length(data) + 1L]] <- readTypedObject(inputCon, type)
  }
  data # this is a list of named lists now
}

readMultipleObjectsWithKeys <- function(inputCon) {
  # readMultipleObjectsWithKeys will read multiple continuous objects from
  # a DataOutputStream. There is no preceding field telling the count
  # of the objects, so the number of objects varies, we try to read
  # all objects in a loop until the end of the stream. This function
  # is for use by gapply. Each group of rows is followed by the grouping
  # key for this group which is then followed by next group.
  keys <- list()
  data <- list()
  subData <- list()
  while (TRUE) {
    # If reaching the end of the stream, type returned should be "".
    type <- readType(inputCon)
    if (type == "") {
      break
    } else if (type == "r") {
      type <- readType(inputCon)
      # A grouping boundary detected
      key <- readTypedObject(inputCon, type)
      index <- length(data) + 1L
      data[[index]] <- subData
      keys[[index]] <- key
      subData <- list()
    } else {
      subData[[length(subData) + 1L]] <- readTypedObject(inputCon, type)
    }
  }
  list(keys = keys, data = data) # this is a list of keys and corresponding data
}

readDeserializeInArrow <- function(inputCon) {
  if (requireNamespace("arrow", quietly = TRUE)) {
    # Arrow drops `as_tibble` since 0.14.0, see ARROW-5190.
    useAsTibble <- exists("as_tibble", envir = asNamespace("arrow"))


    # Currently, there looks no way to read batch by batch by socket connection in R side,
    # See ARROW-4512. Therefore, it reads the whole Arrow streaming-formatted binary at once
    # for now.
    dataLen <- readInt(inputCon)
    arrowData <- readBin(inputCon, raw(), as.integer(dataLen), endian = "big")
    batches <- arrow::RecordBatchStreamReader(arrowData)$batches()

    if (useAsTibble) {
      as_tibble <- get("as_tibble", envir = asNamespace("arrow"))
      # Read all groupped batches. Tibble -> data.frame is cheap.
      lapply(batches, function(batch) as.data.frame(as_tibble(batch)))
    } else {
      lapply(batches, function(batch) as.data.frame(batch))
    }
  } else {
    stop("'arrow' package should be installed.")
  }
}

readDeserializeWithKeysInArrow <- function(inputCon) {
  data <- readDeserializeInArrow(inputCon)

  keys <- readMultipleObjects(inputCon)

  # Read keys to map with each groupped batch later.
  list(keys = keys, data = data)
}

readRowList <- function(obj) {
  # readRowList is meant for use inside an lapply. As a result, it is
  # necessary to open a standalone connection for the row and consume
  # the numCols bytes inside the read function in order to correctly
  # deserialize the row.
  rawObj <- rawConnection(obj, "r+")
  on.exit(close(rawObj))
  readObject(rawObj)
}
