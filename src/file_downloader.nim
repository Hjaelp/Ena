# Ena - file_downloader.nim
# Copyright 2018 - Joseph A.

import os
import httpclient, strutils, strformat, logging

import cf_client

type FileDownloader = ref object
  client: HttpClient
  file_dir: string

type Downloader_Options* = enum 
    dNo_files,
    dThumbnails,
    dAll_files

type File_channel = Channel[tuple[previewfilename: string, orig_filename: string, board: string, mode: Downloader_Options]]

var file_channel*: File_channel
file_channel.open()

const IMAGE_CDN: string = "https://i.4cdn.org"

proc fetch(self: var FileDownloader, file: tuple) =
  let subdir1: string = file.orig_filename.substr(0,3)
  let subdir2: string = file.orig_filename.substr(4,5)

  let thumbUrl: string = fmt("{IMAGE_CDN}/{file.board}/{file.previewfilename}")
  let thumbDestination: string = fmt("{self.file_dir}/{file.board}/thumb/{subdir1}/{subdir2}/{file.previewfilename}")
  var imageUrl: string
  var imageDestination: string

  if file.mode == dAll_files:
    imageUrl = fmt("{IMAGE_CDN}/{file.board}/{file.orig_filename}")
    imageDestination = fmt("{self.file_dir}/{file.board}/image/{subdir1}/{subdir2}/{file.orig_filename}")

  if not existsDir(fmt"{self.file_dir}/{file.board}/image/{subdir1}/{subdir2}"):
    createDir(fmt"{self.file_dir}/{file.board}/thumb/{subdir1}/{subdir2}")
    createDir(fmt"{self.file_dir}/{file.board}/image/{subdir1}/{subdir2}")

  try:
    info("Downloading file: "&file.orig_filename)
    self.client.cf_downloadFile(thumbUrl, thumbDestination)

    if file.mode == dAll_files:
      self.client.cf_downloadFile(imageUrl, imageDestination)
  except:
    let error = getCurrentExceptionMsg()
    if error.split(" ")[0] != "404":
      if error.find("closed socket") > -1:
        error(fmt"File downloader socket is closed. Recreating HTTP client. - {error}")
      else:
        error(fmt"Error downloading file {file.orig_filename} - {error}")

      self.client.close()
      self.client = newScrapingClient()
      notice("Adding to the back of the queue...")
      file_channel.send(file)

proc poll(self: var FileDownloader) =
  var file = file_channel.recv()
  self.fetch(file)


proc initFileDownloader*(data: tuple[logger: Logger, file_dir: string]) {.thread.} =
  var dl = FileDownloader(client: newScrapingClient(), file_dir: data.file_dir)

  addHandler(data.logger)

  while true:
    dl.poll()
    sleep(250)