version       = "0.1.0"
author        = "Joseph A."
description   = "Yet another imageboard dumper."
license       = "MIT"

task build_postgres, "Building debug w/ PostgreSQL support":
  exec "nim c --d:ssl -d:release --threads:on --define:USE_POSTGRES --o:ena src/main.nim"
  exec "nim c --d:ssl -d:release --threads:on --define:USE_POSTGRES --o:board_stats src/stats.nim"
  setCommand "nop"
  
task build, "Building debug":
  --threads:on
  --d:ssl
  exec "nim c -d:ssl -d:release --threads:on --o:ena src/main.nim"
  exec "nim c -d:ssl -d:release --threads:on --o:board_stats src/stats.nim"
  setCommand "nop"