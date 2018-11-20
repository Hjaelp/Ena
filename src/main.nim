# Ena - main.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, tables, deques, threadpool
import httpclient, parsecfg, strutils, logging

import scraper
import file_downloader

var con_logger: Logger
var boards: seq[Board]
type BoardThread = tuple[logger: Logger, board: ptr Board]
type FileThread =  tuple[logger: Logger, file_dir: string]

proc on_quit() {.noconv.} =
  when defined(windows):
    setupForeignThreadGc()
    addHandler(con_logger)

  sleep(1000)
  notice("Waiting for the file downloaders to finish their queue before shutting down.")
  for i, _ in boards:
    boards[i].end_scraping()

  sleep(5000) # give the queue enough time to get populated.
  
  var remaining:int = file_channel.peek()
  while remaining > 1:
    remaining = file_channel.peek()
    notice($remaining&" files remaining.")
    sleep(2000)

  sleep(5000) # in case the last file is still being downloaded.
  notice("Bye!")
  quit(1)


proc poll_board(brd: ptr Board) {.async.} =
  var board = brd[]
  let delay: int = board.config.api_cooldown

  while true:
    board.poll_queue()
    await sleepasync(delay)

proc poll_board(data: BoardThread) {.thread.} =
  addHandler(data.logger)

  var board = data.board[]
  let delay: int = board.config.api_cooldown

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
    GRACEFUL_EXIT =     config.getSectionValue("Config", "Finish_queue_before_exit") == "true"
    FILE_DIRECTORY =    config.getSectionValue("Config", "File_Base_directory")
    FILE_THREADS  =     parseInt(config.getSectionValue("Config", "File_Download_Threads"))
    LOG_LEVEL =         config.getSectionValue("Config", "Logging_level").toLower()
    BOARDS_TO_ARCHIVE = config.getSectionValue("Boards", "Boards_to_archive").split(";")
    MULTITHREADED =     config.getSectionValue("Config", "Multithreaded") == "true"
    RESTORE_STATE =     config.getSectionValue("Boards", "Restore_Previous_State") == "true"

  if GRACEFUL_EXIT:
    setControlCHook(on_quit)

  con_logger = newConsoleLogger(fmtStr = "$time | $levelname | ", 
    levelThreshold = 
      if   LOG_LEVEL == "verbose": lvlInfo
      elif LOG_LEVEL == "notice":  lvlNotice
      elif LOG_LEVEL == "error":   lvlError
      else: lvlNone)
  
  addHandler(con_logger)


  var file_dl_threads: seq[Thread[FileThread]] = 
    newSeq[Thread[FileThread]](FILE_THREADS)

  for i, _ in file_dl_threads:
    createThread(file_dl_threads[i], 
      initFileDownloader, 
      (con_logger, FILE_DIRECTORY)
    )

  let db_conn = db_connect(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)

  for board in BOARDS_TO_ARCHIVE:
    let download_thumbs:bool = config.getSectionValue(board, "Download_thumbs") != "false"
    let download_images:bool = config.getSectionValue(board, "Download_images") == "true"
    let scrape_internal:bool = config.getSectionValue(board, "Scrape_internal") == "true"

    let board_api_cooldown:string = config.getSectionValue(board, "Time_between_requests")

    boards.add(
      Board(
        name: board, 
        threads: initTable[int, Topic](), 
        scrape_queue: initDeque[Topic](),
        config: Board_Config(
          api_cooldown: if isDigit(board_api_cooldown): parseInt(board_api_cooldown)
            else: DEFAULT_COOLDOWN,
          file_options: if download_thumbs and download_images: dAll_files
               elif download_thumbs: dThumbnails
               else: dNo_files,
          restore_state: RESTORE_STATE,
          scrape_archive: scrape_internal

        ),
        db: if MULTITHREADED: db_connect(DB_HOST, DB_USERNAME, DB_PASSWORD, DB_NAME)
            else: db_conn,
      )
    )

  if MULTITHREADED:
    db_conn.close()

    notice("Ena $1 now starting in multi-threaded mode, using $2 threads for $3 boards." % 
      [VERSION, $BOARDS_TO_ARCHIVE.len, $BOARDS_TO_ARCHIVE.len])
  
    var board_threads: seq[Thread[BoardThread]] = 
      newSeq[Thread[BoardThread]](BOARDS_TO_ARCHIVE.len)
  
    for i, _ in board_threads:
      createThread(board_threads[i], poll_board, (con_logger, addr boards[i]))
      await sleepAsync(500)

    joinThreads(board_threads)

  else:
    notice("Ena $1 now starting in single-threaded mode, using 1 thread for $2 boards." %
      [VERSION, $BOARDS_TO_ARCHIVE.len])
  
    let num_boards = boards.len-1
  
    notice("Creating database tables and procedures.")

    for i, _ in boards:
      boards[i].init()
  
    notice("Done. Now scraping.")
  
    for i, _ in boards:
      asyncCheck poll_board(addr boards[i])
      await sleepAsync(250)



waitFor main()
runForever()
