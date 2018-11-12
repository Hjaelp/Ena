# Ena - main.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, tables, deques, threadpool
import httpclient, parsecfg, strutils, logging
from math import floor

import scraper
import file_downloader

type FileThread  = tuple[logger: Logger, file_dir: string]

proc poll_board(logger: Logger, brd: Board, delay: int) {.thread.} =
  addHandler(logger)

  var board = brd

  notice("/$1/ | Creating database tables and procedures." % board.name)
  board.init()
  notice("/$1/ | Done. Now scraping." % board.name)

  while true:
    board.poll_queue()
    sleep(delay)


proc main() {.async.} =
  doAssert(existsFile("config.ini"), "Config file not found! Please rename config.example.ini and modify it.")
  
  let config = loadConfig("config.ini")

  let 
    VERSION =           config.getSectionValue("Application", "Version")
    DEFAULT_COOLDOWN =  parseInt(config.getSectionValue("Config", "Default_API_cooldown"))
    DB_HOST =           config.getSectionValue("Config", "DB_host")
    DB_USERNAME =       config.getSectionValue("Config", "DB_username")
    DB_PASSWORD =       config.getSectionValue("Config", "DB_password")
    DB_NAME =           config.getSectionValue("Config", "DB_database_name")
    FILE_DIRECTORY =    config.getSectionValue("Config", "File_Base_directory")
    FILE_THREADS  =     parseInt(config.getSectionValue("Config", "File_Download_Threads"))
    LOG_LEVEL =         config.getSectionValue("Config", "Logging_level").toLower()
    BOARDS_TO_ARCHIVE = config.getSectionValue("Boards", "Boards_to_archive").split(";")
    MULTITHREADED =     config.getSectionValue("Config", "Multithreaded") == "true"


  let con_logger = newConsoleLogger(fmtStr = "$time | $levelname | ", 
    levelThreshold = 
      if   LOG_LEVEL == "verbose": lvlInfo
      elif LOG_LEVEL == "notice":  lvlNotice
      elif LOG_LEVEL == "error":   lvlError
      else: lvlNone)
  
  addHandler(con_logger)


  var file_dl_threads: seq[Thread[FileThread]] = 
    newSeq[Thread[FileThread]](FILE_THREADS)

  for i, t in file_dl_threads:
    createThread(file_dl_threads[i], 
      initFileDownloader, 
      (con_logger, FILE_DIRECTORY)
    )

  let db_conn = db_connect(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)

  var boards: seq[Board]
  for board in BOARDS_TO_ARCHIVE:
    let download_thumbs:bool = config.getSectionValue(board, "Download_thumbs") != "false"
    let download_images:bool = config.getSectionValue(board, "Download_images") == "true"
    let scrape_internal:bool = config.getSectionValue(board, "Scrape_internal") == "true"

    let board_api_cooldown:string = config.getSectionValue(board, "Time_between_requests")

    boards.add(
      Board(
        name: board, 
        threads: initTable[int, Topic](), 
        client: newHttpClient(), 
        scrape_queue: initDeque[Topic](),
        file_options: if download_thumbs and download_images: dAll_files
                      elif download_thumbs: dThumbnails
                      else: dNo_files,
        scrape_archive: scrape_internal,
        db: if MULTITHREADED: db_connect(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)
            else: db_conn,
        api_cooldown: if isDigit(board_api_cooldown): parseInt(board_api_cooldown)
            else: DEFAULT_COOLDOWN
      )
    )

  if MULTITHREADED:
    db_conn.close()

    notice("Ena $1 now starting in multi-threaded mode, using $2 threads for $3 boards." % 
      [VERSION, $BOARDS_TO_ARCHIVE.len, $BOARDS_TO_ARCHIVE.len])
  
    for i, t in BOARDS_TO_ARCHIVE:
      spawn poll_board(con_logger, boards[i], boards[i].api_cooldown)

    sync()

  else:
    notice("Ena $1 now starting in single-threaded mode, using 1 thread for $2 boards." %
      [VERSION, $BOARDS_TO_ARCHIVE.len])
  
    let num_boards = boards.len-1
  
    notice("Creating database tables and procedures.")

    for i, b in boards:
      boards[i].init()
  
    notice("Done. Now scraping.")
  
    while true:
      for i in 0..num_boards:
        boards[i].poll_queue()
        await sleepAsync(DEFAULT_COOLDOWN)



waitFor main()
runForever()
