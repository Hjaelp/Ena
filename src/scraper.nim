# Ena - scraper.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, deques, tables
import httpclient, json, re
import strutils, sequtils, strformat, logging

when defined(USE_POSTGRES):
  import db_postgres
  import db_pgsql_setup
  export db_pgsql_setup.db_connect, db_postgres.DbConn, db_postgres.close
else:
  import db_mysql
  import db_mysql_setup
  export db_mysql_setup.db_connect, db_mysql.DbConn, db_mysql.close

import cf_client
import file_downloader
import html_purifier

type Scrape_options = enum 
    sEntire_Topic,
    sUpdate_Topic,
    sCheck_Status,
    sEnding

type 
  Board_Config* = ref object
    api_cooldown*: int
    file_options*: Downloader_Options
    restore_state*: bool
    scrape_archive*: bool
    api_endpoint: string
    api_threads_endpoint: string
    image_loc: string
    thumb_loc: string
    thumb_ext*: string

  Board* = ref object
    api_lastmodified*: string
    client*: Httpclient
    config*: Board_Config
    name*: string
    threads*: Table[int, Topic]
    scrape_queue*: Deque[Topic]
    db*: DbConn


  Topic* = ref object
    num*: int
    last_modified*: int
    posts*: seq[int] 
    queue_option*: Scrape_options

  Post* = ref object
    num*: int
    parent*: int
    time*: int
    capcode*: string
    name*: string
    trip*: string
    subject*: string
    comment*: string
    sticky*: int
    locked*: int
    poster_hash*: string
    country*: string
    file*: File
    extra_files*: seq[File]

  File* = ref object
    filename*: string
    width*: int
    height*: int
    tn_width*: int
    tn_height*: int
    fsize*: int
    hash*: string
    orig_filename*: string
    preview_filename*: string
    spoiler*: int
    exif*: string
    board*: string

proc newMediaFile (self: Board, jsonPost: JsonNode): File =
  let thumb_ext =
    when defined(VICHAN):
      if self.config.thumb_ext.len > 0:
        self.config.thumb_ext
      else:
        if jsonPost["ext"].getStr() notin [".webm",".mp4"]:
          jsonPost["ext"].getStr() 
        else:
          ".jpg"
    else:
      ".jpg"

  return File(
    filename: (jsonPost["filename"].getStr()&jsonPost["ext"].getStr()),
    width: jsonPost{"w"}.getInt(),
    height: jsonPost{"h"}.getInt(),
    tn_width: jsonPost{"tn_w"}.getInt(),
    tn_height: jsonPost{"tn_h"}.getInt(),
    fsize: jsonPost["fsize"].getInt(),
    hash: jsonPost{"md5"}.getStr(),
    orig_filename: 
      when not defined(VICHAN): 
        ($jsonPost["tim"].getInt()&jsonPost["ext"].getStr())
      else:
        ($jsonPost["tim"].getStr()&jsonPost["ext"].getStr()),
    preview_filename: 
      when not defined(VICHAN): 
        ($jsonPost["tim"].getInt()&"s.jpg")
      else:
        ($jsonPost["tim"].getStr()&thumb_ext),
    spoiler: jsonPost{"spoiler"}.getInt()
  )

proc newPost(self: Board, jsonPost: JsonNode, thread_num: int): Post =
  var media_file: File
  var extra_files: seq[File]

  if not jsonPost.hasKey("no"):
    return

  if jsonPost.hasKey("filename"):
    media_file = self.newMediaFile(jsonPost)

    when defined(VICHAN):
      if jsonPost.hasKey("extra_files"):
        for f in jsonPost["extra_files"]:
          let extra_file = self.newMediaFile(f)
          extra_files.add(extra_file)

  else:
    media_file = File()

  let name    = sanitizeField(jsonPost{"name"}.getStr())
  let subject = sanitizeField(jsonPost{"sub"}.getStr())
  let comment = cleanHTML(jsonPost{"com"}.getStr())

  return Post(
      parent: thread_num,
      num: jsonPost["no"].getInt(),
      time: jsonPost{"time"}.getInt(),
      capcode: jsonPost{"capcode"}.getStr().substr(0,0).toupper(),
      name: name,
      trip: jsonPost{"trip"}.getStr(),
      subject: subject,
      comment: comment,
      sticky: jsonPost{"sticky"}.getInt(),
      locked: jsonPost{"closed"}.getInt(),
      poster_hash: jsonPost{"id"}.getStr(),
      country:  if jsonPost.hasKey("country_name"):
                  if jsonPost.hasKey("country"):
                    jsonPost["country"].getStr()
                  else: jsonPost{"troll_country"}.getStr().toLower()
                else: "",
      file: media_file,
      extra_files: extra_files
    )

proc end_scraping*(self:Board) =
  self.scrape_queue.clear()
  self.scrape_queue.addfirst(Topic(queue_option: sEnding))
  notice(fmt"/{self.name}/ | Ending.")

proc print_queue(self:Board): string =
  var new_thread, update_thread, status_thread: int = 0
  for t in self.scrape_queue:
    case t.queue_option
    of sEntire_Topic:
      inc new_thread
    of sUpdate_Topic:
      inc update_thread:
    of sCheck_Status:
      inc status_thread
    else: discard

  return fmt"(New: {new_thread}, Upd: {update_thread}, Chk: {status_thread})"

proc create_board_table*(self: Board) =
  create_tables(self.name, self.db)

proc create_sql_procedures*(self: Board) =
  create_procedures(self.name, self.db)

proc media_file_exists(self: Board, hash: string, op: bool): array[0..1, string] =
  var row: seq[Row]

  when defined(USE_POSTGRES):
    if op:
      row = self.db.getAllRows(sql(&"SELECT media, coalesce(preview_op, '') FROM \"{self.name}_images\" WHERE media_hash = ? limit 1"), hash)
    else:
      row = self.db.getAllRows(sql(&"SELECT media, coalesce(preview_op, preview_reply, '') FROM \"{self.name}_images\" WHERE media_hash = ? limit 1"), hash)
  else:
    if op:
      row = self.db.getAllRows(sql(fmt"SELECT media, coalesce(preview_op, '') FROM `{self.name}_images` WHERE media_hash = ? limit 1"), hash)
    else:
      row = self.db.getAllRows(sql(fmt"SELECT media, coalesce(preview_op, preview_reply, '') FROM `{self.name}_images` WHERE media_hash = ? limit 1"), hash)

  if row.len > 0:
    result = [row[0][0], row[0][1]]
  else:
    result = ["", ""]

proc download_file(self: Board, file: File, is_op: bool = false) =
  if self.config.file_options == dNo_files:
    return

  if file.hash != "":
    let old_file = self.media_file_exists(file.hash, is_op)
    if old_file[0] == "":
      file_channel.send(
        (
          preview_url: self.config.thumb_loc&"/"&file.preview_filename, 
          orig_url: self.config.image_loc&"/"&file.orig_filename,
          preview_filename: file.preview_filename,
          orig_filename: file.orig_filename,
          board: self.name,
          mode: self.config.file_options
        )
      )
    elif old_file[1] == "":
      file_channel.send(
        (
          preview_url: self.config.thumb_loc&"/"&file.preview_filename, 
          orig_url: "",
          preview_filename: file.preview_filename,
          orig_filename: "",
          board: self.name,
          mode: dThumbnails
        )
      )
      file.orig_filename = old_file[0]
    else: 
      #info(fmt"Ignoring filename {file.orig_filename} because hash already exists.")
      file.orig_filename = old_file[0]
      file.preview_filename = old_file[1]

proc enqueue_for_check(self: var Board, thread: Topic) =
  self.scrape_queue.addLast(thread)

proc insert_post(self: Board, post: Post) =
  self.download_file(post.file)

  when defined(USE_POSTGRES):
    self.db.exec(sql(fmt"""INSERT INTO "{self.name}" (media_id, poster_ip, num, subnum, thread_num, 
      op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
      media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
      deleted, capcode, email, name, trip, title, comment,
      sticky, locked, poster_hash, poster_country, exif) 
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"""),
      0,0,post.num, 0, post.parent, 0, post.time, 0, post.file.preview_filename, post.file.tn_width, post.file.tn_height,
      post.file.filename, post.file.width, post.file.height, post.file.fsize, post.file.hash, post.file.orig_filename, post.file.spoiler,
      0, post.capcode, "", post.name, post.trip, post.subject, post.comment, post.sticky, post.locked, 
      post.poster_hash, post.country, post.file.exif
    )
  else:
    self.db.exec(sql(fmt"""INSERT IGNORE INTO `{self.name}` (media_id, poster_ip, num, subnum, thread_num, 
      op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
      media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
      deleted, capcode, email, name, trip, title, comment,
      sticky, locked, poster_hash, poster_country, exif) 
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""),
      0,0,post.num, 0, post.parent, 0, post.time, 0, post.file.preview_filename, post.file.tn_width, post.file.tn_height,
      post.file.filename, post.file.width, post.file.height, post.file.fsize, post.file.hash, post.file.orig_filename, post.file.spoiler,
      0, post.capcode, "", post.name, post.trip, post.subject, post.comment, post.sticky, post.locked, 
      post.poster_hash, post.country, post.file.exif
    )

proc set_thread_archived(self: var Board, thread_num: int, archived_timestamp: int) =
  notice(fmt"/{self.name}/ {print_queue(self)} | Setting status of thread #{thread_num} as archived.")
  self.threads.del(thread_num)

  when defined(USE_POSTGRES):
    self.db.exec(sql(&"UPDATE \"{self.name}\" SET timestamp_expired = ? WHERE thread_num = ? AND op = true"), archived_timestamp,thread_num)
  else:
    self.db.exec(sql(fmt"UPDATE `{self.name}` SET timestamp_expired = ? WHERE thread_num = ? AND op = 1"), archived_timestamp,thread_num)

proc set_thread_deleted(self: var Board, thread_num: int) =
  notice(fmt"/{self.name}/ {print_queue(self)} | Setting status of thread #{thread_num} as deleted.")
  self.threads.del(thread_num)
  when defined(USE_POSTGRES):
    self.db.exec(sql(&"UPDATE \"{self.name}\" SET deleted = true WHERE thread_num = ? AND op = true"), thread_num)
  else:
    self.db.exec(sql(fmt"UPDATE `{self.name}` SET deleted = 1 WHERE thread_num = ? AND op = 1"), thread_num)

proc set_posts_deleted(self: var Board, thread_num: int, post_nums: seq[int]) =
  notice(fmt"/{self.name}/ {print_queue(self)} | Deleting {post_nums.len} post(s) in thread #{thread_num}.")

  self.threads[thread_num].posts = self.threads[thread_num].posts.filter(proc(x: int): bool = not(x in post_nums))

  when defined(USE_POSTGRES):
    self.db.exec(sql(&"UPDATE \"{self.name}\" SET deleted = true WHERE num in ("&post_nums.join(",")&")"))
  else:
    self.db.exec(sql(fmt"UPDATE `{self.name}` SET deleted = 1 WHERE num in ("&post_nums.join(",")&")"))

proc check_thread_status(self: var Board, thread: var Topic) =
  var status: JsonNode
  try:
    self.client.headers.del("If-Modified-Since")
    let body = self.client.cf_getContent(fmt"{self.config.api_threads_endpoint}/{thread.num}.json")
    if body.len == 0:
      raise newException(JsonParsingError, fmt"Received empty body for Thread #{thread.num}")

    status = parseJson(body)
  except HttpRequestError:
    let error = getCurrentExceptionMsg()
    if error.split(" ")[0] == "404":
      self.set_thread_deleted(thread.num)
    else:
      error(fmt"/{self.name}/ | check_thread_status(): Received HTTP error: {error}.")
      self.client.restart()
      self.enqueue_for_check(thread)
    return
  except:
    error(fmt"/{self.name}/ | check_thread_status(): Non-HTTP exception raised. Exception: {getCurrentExceptionMsg()}.")
    sleep(3000)
    self.client.restart()
    self.enqueue_for_check(thread)
    return

  if status.hasKey("posts") and status["posts"].len > 0:
    let archived_timestamp:int = status["posts"][0]{"archived_on"}.getInt()
    if archived_timestamp > 0:
      self.set_thread_archived(thread.num, archived_timestamp)
  else:
    self.enqueue_for_check(thread)

proc scrape_thread(self: var Board, thread: var Topic) =
  var posts: JsonNode

  try:
    self.client.headers.del("If-Modified-Since")
    let body = self.client.cf_getContent(fmt"{self.config.api_threads_endpoint}/{thread.num}.json")
    if body.len == 0:
      raise newException(JsonParsingError, fmt"Received empty body for Thread #{thread.num}")

    posts = parseJson(body)
  except HttpRequestError:
    let error = getCurrentExceptionMsg()
    if error.split(" ")[0] == "404":
      return
    elif error.split(" ")[0] == "500":
      self.client.restart()
      self.enqueue_for_check(thread)
    else:
      error(fmt"/{self.name}/ | scrape_thread(): Received Exception: {getCurrentExceptionMsg()}.")
      self.enqueue_for_check(thread)
    return
  except:
    let error = getCurrentExceptionMsg()
    error(fmt"/{self.name}/ | scrape_thread(): Non-HTTP exception raised. Exception: {error}.")
    sleep(3000)
    self.client.restart()
    self.enqueue_for_check(thread)
    return

  if not posts.hasKey("posts"):
    return

  posts = posts["posts"]
  let queue_option = thread.queue_option

  if queue_option == sEntire_Topic:
    let archived_timestamp: int = posts[0]{"archived_on"}.getInt()

    var op_post: Post = self.newPost(posts[0], thread.num)

    if op_post == nil:
      error(fmt"/{self.name}/ | OP post of {thread.num} doesn't exist. Discarding.")
      #self.enqueue_for_check(thread)
      return

    if op_post.locked == 1 and archived_timestamp > 0:
      op_post.locked = 0

    self.download_file(op_post.file, true)
  
    notice(fmt"/{self.name}/ {print_queue(self)} | Inserting Thread #{thread.num} ({posts.len} posts).")

    self.db.exec(sql"START TRANSACTION")
  
    when defined(USE_POSTGRES):
      self.db.exec(sql(fmt"""INSERT INTO "{self.name}" (media_id, poster_ip, num, subnum, thread_num, 
        op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
        media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
        deleted, capcode, email, name, trip, title, comment,
        sticky, locked, poster_hash, poster_country, exif) 
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"""),
        0,0,op_post.num, 0, op_post.num, 1, op_post.time, archived_timestamp, op_post.file.preview_filename, op_post.file.tn_width, 
        op_post.file.tn_height, op_post.file.filename, op_post.file.width, op_post.file.height, op_post.file.fsize, op_post.file.hash, 
        op_post.file.orig_filename, op_post.file.spoiler, 0, op_post.capcode, "", op_post.name, op_post.trip, op_post.subject, 
        op_post.comment, op_post.sticky, op_post.locked, op_post.poster_hash, op_post.country, op_post.file.exif
      )
    else:
      self.db.exec(sql(fmt"""INSERT IGNORE INTO `{self.name}` (media_id, poster_ip, num, subnum, thread_num, 
        op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
        media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
        deleted, capcode, email, name, trip, title, comment,
        sticky, locked, poster_hash, poster_country, exif) 
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""),
        0,0,op_post.num, 0, op_post.num, 1, op_post.time, archived_timestamp, op_post.file.preview_filename, op_post.file.tn_width, 
        op_post.file.tn_height, op_post.file.filename, op_post.file.width, op_post.file.height, op_post.file.fsize, op_post.file.hash, 
        op_post.file.orig_filename, op_post.file.spoiler, 0, op_post.capcode, "", op_post.name, op_post.trip, op_post.subject, 
        op_post.comment, op_post.sticky, op_post.locked, op_post.poster_hash, op_post.country, op_post.file.exif
      )
  
    for i in 0..<posts.len:
      let post = self.newPost(posts[i], thread.num)
      if post != nil and post.num > 0:
        thread.posts.add(post.num)
        self.insert_post(post)
  
    self.db.exec(sql"COMMIT")


  elif queue_option == sUpdate_Topic:
    let old_posts: seq[int] = thread.posts
    var api_posts: seq[int] = @[]
    var deleted_posts: seq[int] = @[]
    var new_posts: int = 0

    for post in posts:
      let num = post{"no"}.getInt()
      if num > 0:
        api_posts.add(num)

    for old_post in old_posts:
      if not(old_post in api_posts):
        deleted_posts.add(old_post)

    if deleted_posts.len > 0: 
      self.set_posts_deleted(thread.num, deleted_posts)

    self.db.exec(sql"START TRANSACTION")

    for post in posts:
      let post_num = post{"no"}.getInt()
      if post_num > 0 and not(post_num in old_posts):
        var postRef = self.newPost(post, thread.num)
        if postRef != nil and postRef.num > 0:
          self.insert_post(postRef)
          thread.posts.add(post_num)
          inc(new_posts)

    self.db.exec(sql"COMMIT")

    if new_posts > 0:
      info(fmt"/{self.name}/ {print_queue(self)} | inserting {new_posts} new post(s) into {$thread.num}.")


proc add_previous_threads(self: Board) =
  var i = 0

  when defined(USE_POSTGRES):
    let stmt = sql(fmt"""SELECT t1.thread_num,
                                STRING_AGG(t1.num::character VARYING, ','),
                                MAX(t1.TIMESTAMP) AS highest
                         FROM "{self.name}" t1
                         INNER JOIN
                             (SELECT thread_num
                              FROM "{self.name}_threads"
                              ORDER BY time_bump DESC
                              LIMIT 150) t2 ON t2.thread_num = t1.thread_num
                         GROUP BY t1.thread_num""")

  else:
    self.db.exec(sql"SET SESSION group_concat_max_len = 65536")
    let stmt = sql(fmt"""SELECT t1.thread_num,
                              GROUP_CONCAT(t1.num),
                              MAX(t1.TIMESTAMP) AS highest
                       FROM `{self.name}` t1
                       INNER JOIN
                           (SELECT thread_num
                            FROM `{self.name}_threads`
                            ORDER BY time_bump DESC
                            LIMIT 150) t2 ON t2.thread_num = t1.thread_num
                       GROUP BY thread_num""")

  for row in self.db.fastRows(stmt):
    let thread_num = parseInt(row[0])
    let filter = row[1].split(',').filter(proc(i: string): bool = return i != "")
    let posts = filter.map(proc(i: string): int = parseInt(i))
    let new_thread = Topic(num: thread_num, posts: posts, last_modified: parseInt(row[2]), queue_option: sUpdate_Topic)
    self.threads.add(thread_num, new_thread)
    inc i

  notice(fmt"/{self.name}/ | Added {i} threads.")

proc scrape_archived_threads*(self: var Board) =
  info("Scraping the internal archives.")
  try:
    var archive = parseJson(self.client.cf_getContent(fmt"{self.config.api_endpoint}/archive.json"))
    for thread in archive:
      let new_thread = Topic(num: thread.getInt(), posts: @[], last_modified: 0, queue_option: sEntire_Topic)
      self.enqueue_for_check(new_thread)
  except:
    error("Unable to scrape the internal archive! Error: "&getCurrentExceptionMsg())

  discard


proc scrape*(self: var Board) =
  if self.api_lastmodified != "":
    self.client.headers["If-Modified-Since"] =  self.api_lastmodified

  var live_threads: seq[int] = @[]

  info(fmt"/{self.name}/ {print_queue(self)} | Catalog | Checking for changes.")
  var response: Response
  try:
    response = self.client.cf_get(fmt"{self.config.api_endpoint}/threads.json")
    if response != nil and response.body != "":
      let catalog = parseJson(response.body)
      for page in catalog:
        if page.hasKey("threads"):
          let threads = page["threads"]
          for thread in threads:
            let thread_num: int = thread{"no"}.getInt()
            live_threads.add(thread_num)
      
            if not (thread_num in self.threads):
              let new_thread = Topic(num: thread_num, posts: @[], last_modified: thread["last_modified"].getInt(), queue_option: sEntire_Topic)
              self.enqueue_for_check(new_thread)
              self.threads.add(thread_num, new_thread)
            else:
              let last_modified: int = thread["last_modified"].getInt()
              var threadRef = self.threads[thread_num]
      
              if last_modified > threadRef.last_modified:
                threadRef.last_modified = last_modified
                threadRef.queue_option = sUpdate_Topic
                self.enqueue_for_check(threadRef)

      for thread in keys(self.threads):
        if not (thread in live_threads):
          var threadRef = self.threads[thread]
          threadRef.queue_option = sCheck_Status
          self.enqueue_for_check(threadRef)

      if response.headers.hasKey("last-modified"):
        self.api_lastmodified = response.headers["last-modified"]

    elif response.status == "304 Not Modified":
      info(fmt"/{self.name}/ | scrape(): Catalog has not been modified.")
      return

    else:
      error(fmt"/{self.name}/ | scrape(): Scraping failed! Response details: {repr(response)}")
  except HttpRequestError:
    error(fmt"/{self.name}/ | scrape(): HTTP Error: {getCurrentExceptionMsg()}")
  except:
    error(fmt"/{self.name}/ | scrape(): Non-HTTP exception raised. Exception: {getCurrentExceptionMsg()}.")
    self.client.restart()
    
  discard


proc newBoard*(site: string, name: string, config: Board_Config, db: DbConn): Board =
  new result
  when not defined(VICHAN):
    result.config = config
    result.config.api_endpoint = "https://a.4cdn.org/"&name
    result.config.api_threads_endpoint = "https://a.4cdn.org/"&name&"/thread"
    result.config.image_loc = "https://i.4cdn.org/"&name
    result.config.thumb_loc = "https://i.4cdn.org/"&name

  else:
    result.config = config
    result.config.api_endpoint = "https://"&site&"/"&name
    result.config.api_threads_endpoint = "https://"&site&"/"&name&"/res"

    if site == "8ch.net":
      result.config.image_loc = "https://media.8ch.net/file_store"
      result.config.thumb_loc = "https://media.8ch.net/file_store/thumb"
    else:
      result.config.image_loc = "https://"&site&"/"&name&"/src"
      result.config.thumb_loc = "https://"&site&"/"&name&"/thumb"

  result.name = name
  result.threads = initTable[int, Topic]()
  result.scrape_queue = initDeque[Topic]()
  result.db = db

proc poll_queue*(self: var Board) =
  if (self.scrape_queue.len > 0):
    var first_thread = self.scrape_queue.popFirst()
    case first_thread.queue_option
    of sEntire_Topic, sUpdate_Topic:
      self.scrape_thread(first_thread)
    of sCheck_Status:
      self.check_thread_status(first_thread)
    of sEnding: 
      self.scrape_queue.addfirst(first_thread)
      sleep(60000)
    else: discard
  else: 
    self.scrape()


proc init*(self: var Board) =
  self.client = newScrapingClient()
  html_purifier.compileRegex()
  self.create_board_table()
  self.create_sql_procedures()

  if self.config.restore_state:
    self.add_previous_threads()

  if self.config.scrape_archive:
    self.scrape_archived_threads()

  self.scrape()


