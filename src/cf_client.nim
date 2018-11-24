# Ena - cf_client.nim
# A port of anorov's Cloudflare-scrape.

import os, osproc, httpclient, strtabs, re, tables, locks
import strutils, uri, logging
from cookies import parseCookies

var headerLock: Lock
initLock(headerLock)

type CF_data = ref object
  cookie{.guard: headerLock.}: string

var cf_data = CF_data(cookie:newStringOfCap(5000))
var headerPtr = addr cf_data

proc getCookieString(cookies: StringTableRef): string =
  result = ""

  for c, v in pairs(cookies):
      if v == "": continue
  
      if result.len > 0:
          result = "$1; $2=$3" % [result, c, v]
      else:
          result = "$2=$3" % [result, c, v]

proc setCookie(client: HttpClient, cookie: string) =
  if cookie.len == 0: return

  if client.headers.hasKey("cookie") and 
     client.headers["cookie"].len > 0:
    var cookiejar = parseCookies(client.headers["cookie"])

    let name = cookie.split('=')[0]

    if cookiejar.hasKey(name):
      cookiejar[name] = ""
      client.headers["cookie"] = getCookieString(cookiejar)

    client.headers["cookie"] = client.headers["cookie"] &
      ("; " & cookie)

  else:
    client.headers["cookie"] = cookie


proc setCookie(client: HttpClient, response: Response) =
  var headers = response.headers
  
  if not headers.hasKey("set-cookie"):
    return
  
  let data = headers.table["set-cookie"]
  for c in data:
    let split = c.split('=')
    if split.len > 1:
      let name = split[0]
      let value = split[1].split(';')[0]
      client.setCookie(name&"="&value)
  
  notice("Cookie changed to "&client.headers["cookie"])
  
  withLock headerLock:
    headerPtr.cookie = client.headers["cookie"]


proc is_captcha*(resp: Response): bool =
  return resp.code.int == 503 and 
    "captcha-bypass" in resp.body

proc is_challenge*(resp: Response): bool =
  result = resp.code.int == 503 and 
           resp.headers["Server"].startswith("cloudflare") == true and 
           "jschl" in resp.body and 
           "jschl_answer" in resp.body

proc cf_solve(client: HttpClient, resp: Response, url: string): Response =
  var body = resp.body
  var matches: array[1, string]
  var jschl_vc, pass, js: string
  let parsed_url = parseUri(url)

  if body.find(re"""name="jschl_vc" value="(\w+)"""", matches) > -1:
    jschl_vc = matches[0]
  else:
    return resp

  if body.find(re"""name="pass" value="(.+?)"""", matches) > -1:
    pass = matches[0]
  else:
    return resp

  if body.find(re"setTimeout\(function\(\){\s+(var s,t,o,p,b,r,e,a,k,i,n,g,f.+?\r?\n[\s\S]+?a\.value =.+?)\r?\n", matches) > -1:
    js = matches[0]
  else:
    return resp

  js = js.replacef(re"a\.value = (.+ \+ t\.length).+", "$1")
  js = js.replace(re"\s{3,}[a-z](?: = |\.).+", "")
  js = js.replace(re"t.length", $parsed_url.hostname.len)
  js = js.replace(re"[\n\\']","")

  js = "console.log(require('vm').runInNewContext('$1', Object.create(null), {timeout: 5000}));" % [js]
  var jschl_answer: string

  try:
    jschl_answer = execProcess("node -e \"$1\"" % [js]).strip()
  except:
    error("Could not evaluate the Cloudflare JS challenge answer! Please ensure Node.js is installed.")
    return resp

  let submit_url = "$1://$2/cdn-cgi/l/chk_jschl?jschl_vc=$3&jschl_answer=$4&pass=$5" % 
    [parsed_url.scheme, parsed_url.hostname, jschl_vc, jschl_answer, pass]


  sleep(8000)

  client.headers["accept"] = "*/*"
  client.headers["referer"] = url

  var redirect = client.get(submit_url)

  client.headers.del("accept")

  if is_challenge(redirect) or is_captcha(redirect):
    return redirect

  client.setCookie(redirect)

  if redirect.code.int in [301,302,303,307]:
    result = client.get(redirect.headers["location"])
  else:
    result = redirect

proc cf_get*(client: HttpClient, url: string): Response =
  withLock headerLock:
    client.headers["cookie"] = headerPtr.cookie
    result = client.request(url, HttpGET)

  client.setCookie(result)
  
  if is_captcha(result):
    error("Ran into a cloudflare Captcha challenge...")
    return result
  
  elif is_challenge(result):
    warn("Ran into a cloudflare JS challenge.")
    withLock headerLock:
      result = client.cf_solve(result, url)

proc cf_getContent*(client: HttpClient, url: string): string =
  let resp = cf_get(client, url)

  if resp.code.is4xx or resp.code.is5xx:
    raise newException(HttpRequestError, resp.status)
  else:
    return resp.body

proc cf_downloadFile*(client: HttpClient, url: string, filename: string) =
  var f: File
  let body = client.cf_getContent(url)

  if open(f, filename, fmWrite):
    f.write(body)
    f.close()
  else:
    raise newException(IOError, "Unable to open file")


proc newScrapingClient*(userAgent = defUserAgent, 
      headers = newHttpHeaders()): HttpClient =

  result = newHttpClient("Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:62.0) Gecko/20100101 Firefox/62.0", timeout = 10_000, maxRedirects = 0)
  result.headers = headers
