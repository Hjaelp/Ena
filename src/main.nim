# Ena - main.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, tables, deques
import httpclient, parsecfg, strutils, logging
from math import floor

import scraper
import file_downloader

type BoardThread = 
  tuple[
    logger: Logger, 
    boards: seq[Board],
    api: int
  ]
type FileThread  = tuple[logger: Logger, file_dir: string]

proc board_chunk(boards: seq[Board], chunks: int): seq[seq[Board]] =
  result = @[]
  let arrlen = boards.len
  var size = (arrlen div chunks)

  var index = 0;
  while index < arrlen: 
      if index + size >= arrlen: 
          size = arrlen - index - 1
          echo size
      result.add([boards[index..(size + index)]]);
      index += (size+1);


proc poll_board(data: BoardThread) {.thread.} =
  addHandler(data.logger)

  notice("thread started") 

  var boards = data.boards
  let num_boards = boards.len-1

  for i in 0..num_boards:
    notice("Creating database tables and procedures for /$1/." % boards[i].name)
    boards[i].init()
    notice("Done. Now scraping /$1/." % boards[i].name)

  while true:
    for i in 0..num_boards:
      boards[i].poll_queue()
      sleep(data.api)


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
    BOARD_THREADS =     parseInt(config.getSectionValue("Config", "Board_Threads"))
    LOG_LEVEL =         config.getSectionValue("Config", "Logging_level").toLower()
    BOARDS_TO_ARCHIVE = config.getSectionValue("Boards", "Boards_to_archive").split(";")
    MULTITHREADED = if BOARD_THREADS > 1 and BOARDS_TO_ARCHIVE.len > 1: true else: false


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
            else: db_conn
      )
    )

  if BOARD_THREADS > 1 and BOARDS_TO_ARCHIVE.len > 1:
    db_conn.close()
    var board_chunks = board_chunk(boards, BOARD_THREADS)

    notice("Ena $1 now starting in multi-threaded mode, using $2 threads for $3 boards." % 
      [VERSION, $board_chunks.len, $BOARDS_TO_ARCHIVE.len])

    var board_threads: seq[Thread[BoardThread]] = 
      newSeq[Thread[BoardThread]](BOARD_THREADS)
  
    for i, t in board_threads:
      createThread(board_threads[i], poll_board, (con_logger, board_chunks[i], API_COOLDOWN))

    joinThreads(board_threads)

  else:
    notice("Ena $1 now starting in single-threaded mode, using 1 thread for $3 boards." %
      [VERSION, $BOARDS_TO_ARCHIVE.len])
  
    let num_boards = boards.len-1
  
    notice("Creating database tables and procedures.")

    for i, b in boards:
      boards[i].init()
  
    notice("Done. Now scraping.")
  
    while true:
      for i in 0..num_boards:
        boards[i].poll_queue()
        await sleepAsync(API_COOLDOWN)



waitFor main()
runForever()
