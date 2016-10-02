import oids, redis, jester, strtabs, tables, nativesockets, strutils, times, httpserver

export redis

type
  TSessionData = object
    id: string
    
type
  TSession* = object
    enabled: bool
    redisInitialized: bool
    redisCon: TRedis
    configData: PStringTable
    
var session*: TSession
    
session.configData = newStringTable(modeCaseInsensitive)
session.configData["host"] = "localhost"
session.configData["port"] = "6379"
session.configData["expiresMinutes"] = $(60 * 24 * 2) #sessions expire in two days

proc connect() =
  session.redisCon = redis.open(session.configData["host"], Port(parseInt(session.configData["port"])))
  session.redisInitialized = true

proc config*(data: varargs[string]) =
  ## Set config values like port and host for redis
  session.enabled = true
  var i = 0
  while true:
    session.configData[data[i]] = data[i+1]
    inc(i)
    if i == data.len-1:
      break
  connect()

proc makeSessionId():string =
  var sid:string = $(genOid())
  sid.delete(sid.len-1, sid.len-1)
  return sid  

proc setExpire(request: Request, sessionId:string):TTimeInfo = 
  var minutes = parseInt(session.configData["expiresMinutes"])
  var plus = (TTime(int(getTime()) + minutes * 60)).getGMTime()
  var seconds = minutes * 60
  discard session.redisCon.expire("session:" & sessionId, seconds)  
  return plus

proc initSession(request: Request, response:PResponse):string =
  session.enabled = true
  var sessionId = makeSessionId()
  setCookie("sessionId", sessionId, request.setExpire(sessionId))
  return sessionId

proc getSessionId(request: Request, response:PResponse):string =
  if not session.enabled:
    connect()
    session.enabled = true
    
  var sessionId:string
  
  if request.cookies != nil:
    if request.cookies.hasKey("sessionId"):
      sessionId = request.cookies["sessionId"]
    else:
      sessionId = initSession(request, response)
  else:
    sessionId = initSession(request, response)
    
  return sessionId

iterator pairs*(s: TSession, request: Request, response:PResponse): tuple[key, value: string] =
  ## iterates over every (key, value) pair in the session `s`.
  var sessionId: string  
  sessionId = getSessionId(request, response)  
  var list = session.redisCon.hGetAll("session:" & sessionId)
  if not isNil(list):
    var i = 0
    while i < list.len and not isNil(list[i]):
      yield (list[i], list[i+1])
      i = i + 2

template forall*(s: TSession, actions: stmt):stmt {.immediate.} =
  # forall session:
  #   echo key, val  
  for key {.inject.}, val {.inject.} in pairs(s, request, response):
    actions
  
template `[]=`*(t: TSession, key, val: string) =
  ## store session data.
  bind setExpire
  var sessionId: string
  
  sessionId = getSessionId(request, response)
  discard session.redisCon.hSet("session:" & sessionId, key, val)
  discard setExpire(request, sessionId) 
  
template `[]`*(t: TSession, key: string):expr =
  ## get session data.
  bind initSession
  var sessionId: string
  
  sessionId = getSessionId(request, response)

  var exists = session.redisCon.exists("session:" & sessionId)
  if exists:
    session.redisCon.hGet("session:" & sessionId, key)
  else:
    sessionId = initSession(request, response)
    ""

template deleteSession*() =
  var sessionId = getSessionId(request, response)
  discard session.redisCon.expire("session:" & sessionId, 0)
