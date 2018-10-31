# Ena - main.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, tables, deques
import httpclient, parsecfg, strutils, logging

import scraper
import file_downloader


proc main() {.async.} =
  doAssert(existsFile("config.ini"), "Config file not found! Please rename config.example.ini and modify it.")
  
  let config = loadConfig("config.ini")

  let 
    VERSION =           config.getSectionValue("Application", "Version")
    API_COOLDOWN =      parseInt(config.getSectionValue("Config", "API_cooldown"))
    DB_HOST =           config.getSectionValue("Config", "DB_host")
    DB_USERNAME =       config.getSectionValue("Config", "DB_username")
    DB_PASSWORD =       config.getSectionValue("Config", "DB_password")
    DB_NAME =           config.getSectionValue("Config", "DB_database_name")
    FILE_DIRECTORY =    config.getSectionValue("Config", "File_Base_directory")
    FILE_THREADS  =     parseInt(config.getSectionValue("Config", "File_Download_Threads"))
    LOG_LEVEL =         config.getSectionValue("Config", "Logging_level").toLower()
    BOARDS_TO_ARCHIVE = config.getSectionValue("Boards", "Boards_to_archive").split(";")


  let con_logger = newConsoleLogger(fmtStr = "$time | $levelname | ", 
    levelThreshold = 
      if   LOG_LEVEL == "verbose": lvlInfo
      elif LOG_LEVEL == "notice":  lvlNotice
      elif LOG_LEVEL == "error":   lvlError
      else: lvlNone)
  
  addHandler(con_logger)

  echo "Ena $1 now starting..." % VERSION

  db_connect(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)

  var boards: seq[Board]
  for board in BOARDS_TO_ARCHIVE:
    let download_thumbs:bool = config.getSectionValue(board, "Download_thumbs") == "true"
    let download_images:bool = config.getSectionValue(board, "Download_images") == "true"
    let scrape_internal:bool = config.getSectionValue(board, "Scrape_internal") == "true"

    boards.add(
      Board(
        name: board, 
        threads: initTable[int, Topic](), 
        client: newHttpClient(), 
        scrape_queue: initDeque[Topic](),
        file_options: if download_thumbs and download_images: dAll_files
                      elif download_thumbs: dThumbnails
                      else: dNo_files,
        scrape_archive: scrape_internal
      )
    )

  var file_dl_threads: seq[Thread[tuple[logger: Logger, file_dir: string]]] = 
    newSeq[Thread[tuple[logger: Logger, file_dir: string]]](FILE_THREADS)

  for i, t in file_dl_threads:
    createThread(file_dl_threads[i], 
      initFileDownloader, 
      (con_logger, FILE_DIRECTORY)
    )

  notice("Creating database tables and procedures.")

  let num_boards = boards.len-1
  for i, b in boards:
    boards[i].create_board_table()
    await sleepAsync(500)
    boards[i].create_sql_procedures()
    await sleepAsync(500)
    boards[i].init()

  notice("Done. Now scraping.")

  while true:
    for i in 0..num_boards:
      poll_queue(boards[i])
      await sleepAsync(API_COOLDOWN)


waitFor main()
runForever()