when defined(USE_POSTGRES):
  import db_postgres
  import db_pgsql_setup
else:
  import db_mysql
  import db_mysql_setup

import os, parsecfg, strformat, strutils, times


template time(test:string, board:string, s: untyped) =
  let t0 = cpuTime()
  s
  echo "$1 for /$2/ took $3 second(s)." % [test, board, $(cpuTime() - t0)]
  echo "------------------------------------------------------------------"



let config = loadConfig("config.ini")

let 
  DB_HOST     = config.getSectionValue("Config", "DB_host")
  DB_USERNAME = config.getSectionValue("Config", "DB_username")
  DB_PASSWORD = config.getSectionValue("Config", "DB_password")
  DB_NAME     = config.getSectionValue("Config", "DB_database_name")

var BOARDS    = @[""]

for param in commandLineParams():
  let split = param.split(':', 2)
  if split.len > 1:
    let key = split[0] 
    let value = split[1]
    if key == "--boards":
      BOARDS = value.split(';')

if BOARDS == @[""]:
  BOARDS = config.getSectionValue("Boards", "Boards_to_archive").split(";")

doAssert(BOARDS != @[""], "No boards to generate stats for.")

db_connect(DB_HOST,DB_USERNAME,DB_PASSWORD,DB_NAME)
db.exec(sql"START TRANSACTION")

echo "Now starting stats generation."

for board in BOARDS:
  time("Table creation", board, board.create_tables())

  when defined(USE_POSTGRES):
    time("Daily statistics", board, 
      db.exec(sql(fmt"""
        INSERT INTO "{board}_daily"
          SELECT 
            FLOOR(timestamp/86400)*86400 AS day, 
            COUNT(*) as posts,
            SUM(case WHEN media_orig != '' THEN 1 ELSE 0 end) AS images,
            SUM(case WHEN email = 'sage' THEN 1 ELSE 0 end) AS sage,
            SUM(case WHEN name = 'Anonymous' AND trip = '' THEN 1 ELSE 0 end) AS anons,
            SUM(case WHEN trip != '' THEN 1 ELSE 0 end) AS trips,
            SUM(case WHEN  name != '' THEN 1 ELSE 0 end) AS names
          FROM "{board}"
          GROUP BY day
        ON CONFLICT (day) DO UPDATE SET
          posts = EXCLUDED.posts,
          images = EXCLUDED.images,
          sage = EXCLUDED.sage,
          anons = EXCLUDED.anons,
          trips = EXCLUDED.trips,
          names = EXCLUDED.names
        """)
      )
    )
    
    time("User ranking", board, 
      db.exec(sql(fmt"""
        INSERT INTO "{board}_users" (name, trip, firstseen, postcount)
          SELECT 
            name,
            trip,
            MIN(timestamp) AS firstseen,
            COUNT(*) AS postcount
          FROM "{board}"
          GROUP BY (name, trip)
        ON CONFLICT (name, trip) DO UPDATE SET
          firstseen = EXCLUDED.firstseen,
          postcount = EXCLUDED.postcount
        """)
      )
    )

  else:
    time("Daily statistics", board, 
      db.exec(sql(fmt"""
        INSERT INTO `{board}_daily`
          SELECT 
            FLOOR(timestamp/86400)*86400 AS day, 
            @posts := COUNT(*) as posts,
            @images := SUM(case WHEN media_orig != '' THEN 1 ELSE 0 end) AS images,
            @sage  := SUM(case WHEN email = 'sage' THEN 1 ELSE 0 end) AS sage,
            @anons := SUM(case WHEN name = 'Anonymous' AND trip = '' THEN 1 ELSE 0 end) AS anons,
            @trips := SUM(case WHEN trip != '' THEN 1 ELSE 0 end) AS trips,
            @names := SUM(case WHEN  name != '' THEN 1 ELSE 0 end) AS names
          FROM `{board}`
          GROUP BY day
        ON DUPLICATE KEY UPDATE
          posts = @posts,
          images = @images,
          sage = @sage,
          anons = @anons,
          trips = @trips,
          names = @names
        """)
      )
    )
    
    time("User ranking", board, 
      db.exec(sql(fmt"""
        INSERT INTO `{board}_users` (name, trip, firstseen, postcount)
          SELECT 
            name,
            trip,
            @min := MIN(timestamp) AS firstseen,
            @posts := COUNT(*) AS postcount
          FROM `{board}`
          GROUP BY name, trip
        ON DUPLICATE KEY UPDATE
          firstseen = @min,
          postcount = @posts
        """)
      )
    )

db.exec(sql"COMMIT")