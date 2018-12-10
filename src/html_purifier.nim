# Ena - html_purifier.nim
# Copyright 2018 - Joseph A.

import re, strutils
from htmlparser import entityToRune, entityToUtf8

var reCapcode {.threadvar.}: Regex
var reLit {.threadvar.}: Regex
var reAbbr {.threadvar.}: Regex
var reExif {.threadvar.}: Regex
var reOekaki {.threadvar.}: Regex
var reBan {.threadvar.}: Regex
var reMoot {.threadvar.}: Regex
var reFortune {.threadvar.}: Regex
var reBold {.threadvar.}: Regex
var reCode {.threadvar.}: Regex
var reMath {.threadvar.}: Regex
var reMath2 {.threadvar.}: Regex
var reSpoiler {.threadvar.}: Regex
var reSpoiler2 {.threadvar.}: Regex
var reNewline {.threadvar.}: Regex
var reTags {.threadvar.}: Regex
var reSJIS {.threadvar.}: Regex

var reVichanHeading {.threadvar.}: Regex
var reVichanBold {.threadvar.}: Regex
var reVichanItalic {.threadvar.}: Regex
var reVichanSpoiler {.threadvar.}: Regex
var reVichanCode {.threadvar.}: Regex
var reVichanStrike {.threadvar.}: Regex
var reVichanUnderline {.threadvar.}: Regex
var reVichanSJIS  {.threadvar.}: Regex

#let reEntity = nre.re("&#?(\\w+);")


proc decodeEntities(str: string): string =
    var split: seq[string] = str.split('&')

    if split.len > 1:
      for i in 1..split.high:
        var tmp = split[i].split(';', 1)
        if tmp.len > 1:
          split[i] = entityToUtf8(tmp[0])&tmp[1]
      result = split.join("")

    else:
        result = str


proc sanitizeField*(field: string): string =
  result = field
  result = decodeEntities(result)
  result = result.replace("\\", "\\\\")


proc cleanHTML*(html: string): string =
    result = html
    when not defined(VICHAN):
        result = result.replace(reCapcode, "")
        result = result.replacef(reLit, "[$1:lit]")
        result = result.replace(reAbbr, "")
        result = result.replace(reExif, "")
        #result = result.replace("</tr>", "\n")
        #result = result.replace("</td>", " | ")
        result = result.replace(reOekaki, "")
        result = result.replacef(reBan, "[banned]$1[/banned]")
        result = result.replacef(reMoot, "[moot]$1[/moot]")
        result = result.replacef(reFortune, "\n\n[fortune color=\"$1\"]$2[/fortune]")
        result = result.replacef(reBold, "[b]$1[/b]")
        result = result.replacef(reCode, "[code]$1[/code]")
        result = result.replacef(reMath, "[math]$1[/math]")
        result = result.replacef(reMath2, "[eqn]$1[/eqn]")
        result = result.replacef(reSpoiler, "[spoiler]$1[/spoiler]")
        result = result.replacef(reSpoiler2, "[spoiler]$1[/spoiler]")
        result = result.replacef(reSJIS, "[sjis]$1[/sjis]")

    else: 
        result = result.replacef(reVichanHeading, "[h]$1[/h]")
        result = result.replacef(reVichanBold, "[b]$1[/b]")
        result = result.replacef(reVichanItalic, "[i]$1[/i]")
        result = result.replacef(reVichanSpoiler, "[spoiler]$1[/spoiler]")
        result = result.replacef(reVichanCode, "[code]$1[/code]")
        result = result.replacef(reVichanStrike, "[s]$1[/s]")
        result = result.replacef(reVichanUnderline, "[u]$1[/u]")
        result = result.replacef(reVichanSJIS, "[sjis]$1[/sjis]")
        result = result.replace("</p>", "\n")

    result = result.replace(reNewline, "\n")
    result = result.replace(reTags, "")
    result = sanitizeField(result)

    # Causes memory leaks so it has to be replaced with decodeEntities(str)
    # nre.replace(h, reEntity, proc (matches: nre.RegexMatch): string =
    #     return entityToUtf8(matches.captures[0])
    # )

proc compileRegex*() =
    when not defined(VICHAN):
        reCapcode = re("<span class=\"capcodeReplies\"><span style=\"font-size: smaller;\"><span style=\"font-weight: bold;\">(?:Administrator|Moderator|Developer) Repl(?:y|ies):</span>.*?</span><br></span>",{reDotAll, reStudy})
        reLit = re("\\[(/?(banned|moot|spoiler|code))\\]",{reDotAll, reStudy})
        reAbbr = re("<span class=\"abbr\">.*?</span>",{reDotAll, reStudy})
        reExif = re("<table class=\"exif\"[^>]*>(.*?)</table>",{reDotAll, reStudy})
        reOekaki = re("<br><br><small><b>Oekaki Post</b>.*?</small>",{reDotAll, reStudy})
        reBan = re("<(?:b|strong) style=\"color:\\s*red;\">(.*?)</(?:b|strong)>",{reDotAll, reStudy})
        reMoot = re("<div style=\"padding: 5px;margin-left: \\.5em;border-color: #faa;border: 2px dashed rgba\\(255,0,0,\\.1\\);border-radius: 2px\">(.*?)</div>",{reDotAll, reStudy})
        reFortune = re("<span class=\"fortune\" style=\"color:(.*?)\"><br><br><b>(.*?)</b></span>",{reDotAll, reStudy})
        reBold = re("<(?:b|strong)>(.*?)</(?:b|strong)>",{reDotAll, reStudy})
        reCode = re("<pre[^>]*>(.*?)</pre>",{reDotAll, reStudy})
        reMath = re("<span class=\"math\">(.*?)</span>",{reDotAll, reStudy})
        reMath2 = re("<div class=\"math\">(.*?)</div>",{reDotAll, reStudy})
        reSpoiler = re("<span class=\"spoiler\"[^>]*>(.*?)</span>",{reDotAll, reStudy})
        reSpoiler2 = re("<s>(.*?)</s>",{reDotAll, reStudy})
        reSJIS = re("<span class=\"sjis\">(.*?)</span>",{reDotAll, reStudy})

    else:
        reVichanHeading = re("<span class=\"heading\">(.*?)</span>", {reDotAll, reStudy})
        reVichanBold = re("<strong>(.*?)</strong>", {reDotAll, reStudy})
        reVichanItalic = re("<em>(.*?)</em>", {reDotAll, reStudy})
        reVichanSpoiler = re("<span class=\"spoiler\">(.*?)</span>", {reDotAll, reStudy})
        reVichanCode  = re("<code>(.*?)</code>", {reDotAll, reStudy})
        reVichanStrike = re("<s>(.*?)</s>", {reDotAll, reStudy})
        reVichanUnderline = re("<u>(.*?)</u>", {reDotAll, reStudy})
        reVichanSJIS  = re("<span class=\"aa\">(.*?)</span>", {reDotAll, reStudy})

    reNewline = re("<br\\s*/?>",{reStudy})
    reTags = re("<[^>]*>",{reStudy})
