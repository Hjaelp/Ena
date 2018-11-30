version       = "0.1.0"
author        = "Joseph A."
description   = "Yet another imageboard dumper."
license       = "MIT"

task build_postgres, "Building w/ PostgreSQL support":
  switch("d", "ssl")
  switch("d", "release")
  switch("threads", "on")

  when defined(windows):
    switch("tlsemulation", "off")

  switch("d", "USE_POSTGRES")

  exec "nim c --o:board_stats src/stats.nim"

  switch("o", "ena")
  setCommand "c", "src/main.nim"



task build_vichan_postgres, "Building w/ Vichan & PostgreSQL support":
  switch("d", "ssl")
  switch("d", "release")
  switch("threads", "on")

  when defined(windows):
    switch("tlsemulation", "off")

  switch("d", "USE_POSTGRES")
  switch("d", "VICHAN")

  exec "nim c --o:board_stats src/stats.nim"

  switch("o", "ena")
  setCommand "c", "src/main.nim"



task build, "Building":
  switch("d", "ssl")
  switch("d", "release")
  switch("threads", "on")
  
  when defined(windows):
    switch("tlsemulation", "off")

  exec "nim c --o:board_stats src/stats.nim"

  switch("o", "ena")
  setCommand "c", "src/main.nim"



task build_vichan, "Building w/ Vichan support":
  switch("d", "ssl")
  switch("d", "release")
  switch("threads", "on")

  when defined(windows):
    switch("tlsemulation", "off")

  switch("d", "VICHAN")

  exec "nim c --o:board_stats src/stats.nim"

  switch("o", "ena")
  setCommand "c", "src/main.nim"

