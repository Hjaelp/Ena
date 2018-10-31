version       = "0.1.0"
author        = "Joseph A."
description   = "Yet another imageboard dumper."
license       = "MIT"

task build_postgres, "Building debug w/ PostgreSQL support":
  --define:USE_POSTGRES
  --threads:on
  --d:ssl
  --o:Ena
  setCommand "c", "src/main.nim"
  
task build, "Building debug":
  --threads:on
  --d:ssl
  --o:Ena
  setCommand "c", "src/main.nim"