# Ena - html_purifier.nim
# Copyright 2018 - Joseph A.

import re, strutils
from htmlparser import entityToRune, entityToUtf8

let reCapcode = re("<span class=\"capcodeReplies\"><span style=\"font-size: smaller;\"><span style=\"font-weight: bold;\">(?:Administrator|Moderator|Developer) Repl(?:y|ies):</span>.*?</span><br></span>",{reDotAll, reStudy})
let reLit = re("\\[(/?(banned|moot|spoiler|code))\\]",{reDotAll, reStudy})
let reAbbr = re("<span class=\"abbr\">.*?</span>",{reDotAll, reStudy})
let reExif = re("<table class=\"exif\"[^>]*>(.*?)</table>",{reDotAll, reStudy})
let reOekaki = re("<br><br><small><b>Oekaki Post</b>.*?</small>",{reDotAll, reStudy})
let reBan = re("<(?:b|strong) style=\"color:\\s*red;\">(.*?)</(?:b|strong)>",{reDotAll, reStudy})
let reMoot = re("<div style=\"padding: 5px;margin-left: \\.5em;border-color: #faa;border: 2px dashed rgba\\(255,0,0,\\.1\\);border-radius: 2px\">(.*?)</div>",{reDotAll, reStudy})
let reFortune = re("<span class=\"fortune\" style=\"color:(.*?)\"><br><br><b>(.*?)</b></span>",{reDotAll, reStudy})
let reBold = re("<(?:b|strong)>(.*?)</(?:b|strong)>",{reDotAll, reStudy})
let reCode = re("<pre[^>]*>(.*?)</pre>",{reDotAll, reStudy})
let reMath = re("<span class=\"math\">(.*?)</span>",{reDotAll, reStudy})
let reMath2 = re("<div class=\"math\">(.*?)</div>",{reDotAll, reStudy})
let reSpoiler = re("<span class=\"spoiler\"[^>]*>(.*?)</span>",{reDotAll, reStudy})
let reSpoiler2 = re("<s>(.*?)</s>",{reDotAll, reStudy})
let reNewline = re("<br\\s*/?>",{reStudy})
let reTags = re("<[^>]*>",{reStudy})
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
    result = result.replace(reCapcode, "")
    result = result.replacef(reLit, "[$1:lit]")
    result = result.replace(reAbbr, "")
    result = result.replacef(reExif, "[exif]$1[/exif]")
    result = result.replace("</tr>", "\n")
    result = result.replace("</td>", " | ")
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
    result = result.replace(reNewline, "\n")
    result = result.replace(reTags, "")
    result = sanitizeField(result)

    # Causes memory leaks so it has to be replaced with decodeEntities(str)
    # nre.replace(h, reEntity, proc (matches: nre.RegexMatch): string =
    #     return entityToUtf8(matches.captures[0])
    # )
