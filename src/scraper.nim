# Ena - scraper.nim
# Copyright 2018 - Joseph A.

import os, asyncdispatch, deques, tables
import httpclient, json, re
import strutils, sequtils, strformat, logging

when defined(USE_POSTGRES):
  import db_postgres
  import db_pgsql_setup
  export db_pgsql_setup.db_connect
else:
  import db_mysql
  import db_mysql_setup
  export db_mysql_setup.db_connect

import file_downloader
import html_purifier

var started = false

type Scrape_options = enum 
    sEntire_Topic,
    sUpdate_Topic,
    sCheck_Status

type 
  Board* = ref object
    api_lastmodified*: string
    client*: Httpclient
    name*: string
    file_options*: Downloader_Options
    scrape_archive*: bool
    threads*: Table[int, Topic]
    scrape_queue*: Deque[Topic]

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

  File* = ref object
    filename*: string
    width*: int
    height*: int
    tn_width*: int
    tn_height*: int
    fsize*: int
    hash*: string
    orig_filename*: string
    previewfilename*: string
    spoiler*: int
    exif*: string
    board*: string


proc newPost(jsonPost: JsonNode, thread_num: int): Post =
  var media_file: File

  if not jsonPost.hasKey("no"):
    return
  
  if jsonPost.hasKey("filename"):
    media_file = File(
      filename: (jsonPost["filename"].getStr()&jsonPost["ext"].getStr()),
      width: jsonPost["w"].getInt(),
      height: jsonPost["h"].getInt(),
      tn_width: jsonPost["tn_w"].getInt(),
      tn_height: jsonPost["tn_h"].getInt(),
      fsize: jsonPost["fsize"].getInt(),
      hash: jsonPost{"md5"}.getStr(),
      orig_filename: ($jsonPost["tim"].getInt()&jsonPost["ext"].getStr()),
      previewfilename: ($jsonPost["tim"].getInt()&"s.jpg"),
      spoiler: jsonPost{"spoiler"}.getInt()
    )
  
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
      country: jsonPost{"country"}.getStr(),
      file: media_file
    )

proc create_board_table*(self: Board) =
  create_tables(self.name)

proc create_sql_procedures*(self: Board) =
  create_procedures(self.name)

proc media_file_exists(self: Board, hash: string): array[0..1, string] =
  var row = db.getAllRows(sql(fmt"SELECT media, coalesce(preview_reply, preview_op, '') FROM {self.name}_images WHERE media_hash = ? limit 1"), hash)
  if row.len > 0:
    result = [row[0][0], row[0][1]]
  else:
    result = ["", ""]

proc download_file(self: Board, post: Post) =
  if self.file_options == dNo_files:
    return

  if post.file.hash != "":
    let old_file = self.media_file_exists(post.file.hash)
    if old_file[0] == "":
      file_channel.send((previewfilename: post.file.previewfilename, orig_filename: post.file.orig_filename, board: self.name, mode: self.file_options))
    else: 
      info("Ignoring filename "&post.file.orig_filename&" because hash already exists.")
      post.file.orig_filename = old_file[0]
      post.file.previewfilename = old_file[1]

proc enqueue_for_check(self: var Board, thread: Topic) =
  self.scrape_queue.addLast(thread)

proc insert_post(self: Board, post: Post) =
  self.download_file(post)

  when defined(USE_POSTGRES):
    db.exec(sql(fmt"""INSERT INTO "{self.name}" (media_id, poster_ip, num, subnum, thread_num, 
      op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
      media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
      deleted, capcode, email, name, trip, title, comment,
      sticky, locked, poster_hash, poster_country, exif) 
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"""),
      0,0,post.num, 0, post.parent, 0, post.time, 0, post.file.previewfilename, post.file.tn_width, post.file.tn_height,
      post.file.filename, post.file.width, post.file.height, post.file.fsize, post.file.hash, post.file.orig_filename, post.file.spoiler,
      0, post.capcode, "", post.name, post.trip, post.subject, post.comment, post.sticky, post.locked, 
      post.poster_hash, post.country, post.file.exif
    )
  else:
    db.exec(sql(fmt"""INSERT IGNORE INTO `{self.name}` (media_id, poster_ip, num, subnum, thread_num, 
      op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
      media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
      deleted, capcode, email, name, trip, title, comment,
      sticky, locked, poster_hash, poster_country, exif) 
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""),
      0,0,post.num, 0, post.parent, 0, post.time, 0, post.file.previewfilename, post.file.tn_width, post.file.tn_height,
      post.file.filename, post.file.width, post.file.height, post.file.fsize, post.file.hash, post.file.orig_filename, post.file.spoiler,
      0, post.capcode, "", post.name, post.trip, post.subject, post.comment, post.sticky, post.locked, 
      post.poster_hash, post.country, post.file.exif
    )

proc set_thread_archived(self: var Board, thread_num: int, archived_timestamp: int) =
  notice(fmt"Setting status of thread #{thread_num} from /{self.name}/ as archived.")
  self.threads.del(thread_num)

  when defined(USE_POSTGRES):
    db.exec(sql(&"UPDATE \"{self.name}\" SET timestamp_expired = ? WHERE thread_num = ? AND op = true"), archived_timestamp,thread_num)
  else:
    db.exec(sql(fmt"UPDATE `{self.name}` SET timestamp_expired = ? WHERE thread_num = ? AND op = 1"), archived_timestamp,thread_num)

proc set_thread_deleted(self: var Board, thread_num: int) =
  notice(fmt"Setting status of thread #{thread_num} from /{self.name}/ as deleted.")
  self.threads.del(thread_num)
  when defined(USE_POSTGRES):
    db.exec(sql(&"UPDATE \"{self.name}\" SET deleted = true WHERE thread_num = ? AND op = true"), thread_num)
  else:
    db.exec(sql(fmt"UPDATE `{self.name}` SET deleted = 1 WHERE thread_num = ? AND op = 1"), thread_num)

proc set_posts_deleted(self: var Board, thread_num: int, post_nums: seq[int]) =
  notice(fmt"Deleting {post_nums.len} post(s) in thread #{thread_num} from /{self.name}/.")

  self.threads[thread_num].posts = self.threads[thread_num].posts.filter(proc(x: int): bool = not(x in post_nums))

  when defined(USE_POSTGRES):
    db.exec(sql(&"UPDATE \"{self.name}\" SET deleted = true WHERE num in ("&post_nums.join(",")&")"))
  else:
    db.exec(sql(fmt"UPDATE `{self.name}` SET deleted = 1 WHERE num in ("&post_nums.join(",")&")"))

proc check_thread_status(self: var Board, thread: var Topic) =
  var status: JsonNode
  try:
    status = parseJson(self.client.getContent(fmt"https://a.4cdn.org/{self.name}/thread/{thread.num}.json"))
  except HttpRequestError:
    let error = getCurrentExceptionMsg()
    if error.split(" ")[0] == "404":
      self.set_thread_deleted(thread.num)
    else:
      error(fmt"check_thread_status(): Received HTTP error: {error}.")
      self.enqueue_for_check(thread)
    return
  except:
    error(fmt"check_thread_status(): Non-HTTP exception raised. Creating a new client in 5 seconds. Exception: {getCurrentExceptionMsg()}.")
    sleep(5000)
    self.client.close()
    self.client = newHttpClient()
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
    posts = parseJson(self.client.getContent(fmt"https://a.4cdn.org/{self.name}/thread/{thread.num}.json"))
  except HttpRequestError:
    let error = getCurrentExceptionMsg()
    if error.split(" ")[0] == "404":
      return
    else:
      error(fmt"scrape_thread(): Received Exception: {getCurrentExceptionMsg()}.")
      self.enqueue_for_check(thread)
    return
  except:
    error(fmt"scrape_thread(): Non-HTTP exception raised. Creating a new client in 5 seconds. Exception: {getCurrentExceptionMsg()}.")
    sleep(5000)
    self.client.close()
    self.client = newHttpClient()
    self.enqueue_for_check(thread)
    return

  posts = posts{"posts"}
  let queue_option = thread.queue_option

  if queue_option == sEntire_Topic:
    let archived_timestamp: int = posts[0]{"archived_on"}.getInt()

    var op_post: Post = newPost(posts[0], thread.num)

    if op_post.locked == 1 and archived_timestamp > 0:
      op_post.locked = 0

    self.download_file(op_post)
  
    notice(fmt"Inserting Thread #{thread.num} ({posts.len} posts) from /{self.name}/ into the database.")
    db.exec(sql"START TRANSACTION")
  
    when defined(USE_POSTGRES):
      db.exec(sql(fmt"""INSERT INTO "{self.name}" (media_id, poster_ip, num, subnum, thread_num, 
        op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
        media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
        deleted, capcode, email, name, trip, title, comment,
        sticky, locked, poster_hash, poster_country, exif) 
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT DO NOTHING"""),
        0,0,op_post.num, 0, op_post.num, 1, op_post.time, archived_timestamp, op_post.file.previewfilename, op_post.file.tn_width, 
        op_post.file.tn_height, op_post.file.filename, op_post.file.width, op_post.file.height, op_post.file.fsize, op_post.file.hash, 
        op_post.file.orig_filename, op_post.file.spoiler, 0, op_post.capcode, "", op_post.name, op_post.trip, op_post.subject, 
        op_post.comment, op_post.sticky, op_post.locked, op_post.poster_hash, op_post.country, op_post.file.exif
      )
    else:
      db.exec(sql(fmt"""INSERT IGNORE INTO `{self.name}` (media_id, poster_ip, num, subnum, thread_num, 
        op, timestamp, timestamp_expired, preview_orig, preview_w, preview_h,
        media_filename, media_w, media_h, media_size, media_hash, media_orig, spoiler,
        deleted, capcode, email, name, trip, title, comment,
        sticky, locked, poster_hash, poster_country, exif) 
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"""),
        0,0,op_post.num, 0, op_post.num, 1, op_post.time, archived_timestamp, op_post.file.previewfilename, op_post.file.tn_width, 
        op_post.file.tn_height, op_post.file.filename, op_post.file.width, op_post.file.height, op_post.file.fsize, op_post.file.hash, 
        op_post.file.orig_filename, op_post.file.spoiler, 0, op_post.capcode, "", op_post.name, op_post.trip, op_post.subject, 
        op_post.comment, op_post.sticky, op_post.locked, op_post.poster_hash, op_post.country, op_post.file.exif
      )
  
    for i in 0..<posts.len:
      let post = newPost(posts[i], thread.num)
      if post.num > 0:
        thread.posts.add(post.num)
        self.insert_post(post)
  
    db.exec(sql"COMMIT")


  elif queue_option == sUpdate_Topic:
    let old_posts: seq[int] = thread.posts
    var api_posts: seq[int] = @[]
    var deleted_posts: seq[int] = @[]
    var new_posts: int = 0

    for post in posts:
      api_posts.add(post["no"].getInt())

    for old_post in old_posts:
      if not(old_post in api_posts):
        deleted_posts.add(old_post)

    if deleted_posts.len > 0: 
      self.set_posts_deleted(thread.num, deleted_posts)

    db.exec(sql"START TRANSACTION")

    for post in posts:
      let post_num = post["no"].getInt()
      if not(post_num in old_posts):
        var postRef = newPost(post, thread.num)
        if postRef.num > 0:
          self.insert_post(postRef)
          thread.posts.add(post_num)
          inc(new_posts)

    db.exec(sql"COMMIT")

    if new_posts > 0:
      info(fmt"inserting {new_posts} new post(s) into {$thread.num} from /{self.name}/.")


proc scrape_archived_threads*(self: var Board) =
  info("Scraping the internal archives.")
  try:
    var archive = parseJson(self.client.getContent("https://a.4cdn.org/"&self.name&"/archive.json"))
    for thread in archive:
      let new_thread = Topic(num: thread.getInt(), posts: @[], last_modified: 0, queue_option: sEntire_Topic)
      self.enqueue_for_check(new_thread)
  except:
    error("Unable to scrape the internal archive! Error: "&getCurrentExceptionMsg())

  discard


proc scrape*(self: var Board) =
  if self.api_lastmodified != "":
    self.client.headers = newHttpHeaders({"If-Modified-Since": self.api_lastmodified})

  var live_threads: seq[int] = @[]

  info("Scraping /"&self.name&"/.")
  var response: Response
  try:
    response = self.client.request("https://a.4cdn.org/"&self.name&"/threads.json", httpMethod = HttpGET)
    if response != nil and response.body != "":
      let catalog = parseJson(response.body)
      for page in catalog:
        if page.hasKey("threads"):
          let threads = page["threads"]
          for thread in threads:
            let thread_num: int = thread["no"].getInt()
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
      self.api_lastmodified = response.headers["last-modified"]

    elif response.status == "304 Not Modified":
      info("scrape(): Catalog has not been modified.")
      return

    else:
      error("Scraping {self.name} failed! Response details: "&repr(response))
  except HttpRequestError:
    error("scrape(): HTTP Error: "&getCurrentExceptionMsg())
  except:
    error(fmt"scrape(): Non-HTTP exception raised. Creating a new client in 5 seconds. Exception: {getCurrentExceptionMsg()}.")
    sleep(5000)
    self.client.close()
    self.client = newHttpClient()
    
  discard

proc poll_queue*(self: var Board) =
  if (self.scrape_queue.len > 0):
    var first_thread = self.scrape_queue.popFirst()
    case first_thread.queue_option
    of sEntire_Topic, sUpdate_Topic:
      self.scrape_thread(first_thread)
    of sCheck_Status:
      self.check_thread_status(first_thread)
    else: discard
  else: 
    self.scrape()

proc init*(self: var Board) =
  if self.scrape_archive:
    self.scrape_archived_threads()

  self.scrape()