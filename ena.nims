version       = "0.1.0"
author        = "Joseph A."
description   = "Yet another imageboard dumper."
license       = "MIT"

task build_postgres, "Building w/ PostgreSQL support":
  exec "nim c --d:ssl -d:release --threads:on --tlsemulation:off --define:USE_POSTGRES --o:ena src/main.nim"
  exec "nim c --d:ssl -d:release --threads:on --tlsemulation:off --define:USE_POSTGRES --o:board_stats src/stats.nim"
  setCommand "nop"
  
task build, "Building":
  exec "nim c -d:ssl -d:release --threads:on --tlsemulation:off --o:ena src/main.nim"
  exec "nim c -d:ssl -d:release --threads:on --tlsemulation:off --o:board_stats src/stats.nim"
  setCommand "nop"