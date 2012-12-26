#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# GStreamer based command line audio player .
# Copyright (c) 2012 Tetsu Takaishi.  All rights reserved.
#
# Known bugs:
#  *os-x: strange behavior when sleep-mode
#  *os-x: headphone-jack sense doesn't work while playing
#
from __future__ import with_statement # for python2.5

_version="0.8.0"
_program="gaplay.py"
_copyright = "Copyright (c) 2012 Tetsu Takaishi.  All rights reserved."
_license = "BSD"

import sys, time, re, os, threading, signal
import datetime, os.path, urllib, urllib2, random
import gobject 
import pygst
pygst.require("0.10")
import gst

import traceback

LOAD_PLAYLIST_TIMEOUT = 30

_isdebug = False
#_isdebug = True

def _puts(fmt, *args):
  if _isdebug:
    msg = fmt % args
    sys.stdout.write(msg + "\n")
    # log(msg)

def log(msg): # for debug
  import datetime
  if _isdebug:
    with open("/tmp/gaplay.log","a") as f:
      f.write("%s %s\n" % (datetime.datetime.now().ctime(), msg))

class CommandQueue(object) :
  def __init__(self):
    self.lock = threading.Lock()
    self.cmdlist = []
  
  def add(self, command):
    with self.lock:
      # time.sleep(1) # for debug
      self.cmdlist.append(command)

  def get(self, fallback=None):
    with self.lock:
      try:
        cmd = self.cmdlist.pop(0)
      except IndexError:
        cmd = fallback
    return cmd

def read_command(cmdqueue):
  time.sleep(0.5)
  try:
    while True:
      #time.sleep(0.2)
      line = sys.stdin.readline()
      if not line: cmdline = ["quit"]
      else : cmdline = line.strip().split(None, 1)
      if len(cmdline) > 0:
        _puts("read_command cmdline=%s thread=%s", cmdline, threading.currentThread())
        cmdqueue.add(cmdline)
        if cmdline[0] == "quit": break
  except IOError, exc:
    _puts("read_command IOError - %s", exc)
    cmdqueue.add(["error", str(exc)])
    cmdqueue.add(["quit"])

def sec2str(sec):
  (h, m) = divmod(sec, 3600)
  (m, s) = divmod(m, 60)
  if h: return "%02d:%02d:%02d" % (h, m, s)
  return "%02d:%02d" % (m, s)

def mm2nano(msec):
  return msec * 1000000

# Return value is rounded off to the decimal place
def nano2sec(nano, isround=True):
  return (nano + (500000000 if isround else 0) ) // 1000000000

def to_s(s):
  if isinstance(s,str): return s
  elif isinstance(s, unicode): return s.encode("utf-8", "replace")
  elif s is None: return "none"
  return str(s)

def resp(title, *msgs):
  sys.stdout.write("->" + title)
  if msgs:
    sys.stdout.write(" " + " ".join( (to_s(s) for s in msgs) ))
  sys.stdout.write("\n")

def err_resp(*msgs): resp("ERROR", *msgs)
def wrn_resp(*msgs): resp("WARNING", *msgs)

def match_uri(path, _rx=re.compile(r'(\w+)://')):
  return _rx.match(path)

def match_uri2(path, _rx=re.compile(r'''(http|https|ftp)://''', re.I)):
  "is match http or https or ftp"
  return _rx.match(path)

def match_http(path, _rx=re.compile(r'''https?://''', re.I)):
  return _rx.match(path)

def is_localpath(path):
  m = match_uri(path)
  if m:
    return m.group(1).lower() in ("file", "dvd", "cdda")
  return True

# example
#  t = FileTempl("~/.gaplay/rec%Y-%m-%d.wav")
#  fname = t.nextfile() ; fname #=> '/Users/tetsu/.gaplay/rec2012-08-28.wav'
#  with open(fname,"w") as f : pass
#  fname = t.nextfile() ; fname #=> '/Users/tetsu/.gaplay/rec2012-08-28-1.wav'
class FileTempl(object):
  def __init__(self, templ, date_convert=True):
    self.templ = os.path.abspath( os.path.expanduser(templ) )
    self.date_convert = date_convert
  #
  def nextfile(self, create_dir=True):
    # Replace with strftime
    if self.date_convert:
      fname = datetime.date.today().strftime(self.templ)
    else: fname = self.templ
    # Create dirs
    dirpath = os.path.dirname(fname)
    if not os.path.exists(dirpath):
      if create_dir: os.makedirs(dirpath)
    elif not os.path.isdir(dirpath):
      raise IOError("Fail to create a directory `%s'" % dirpath)

    if not os.path.exists(fname):
      return fname
    (base, ext) = os.path.splitext(fname)
    for n in xrange(1, sys.maxint):
      name = "".join((base, ("-%d" % n), ext))
      _puts("FileTempl#nextfile name=%s",name)
      if not os.path.exists(name): return name
    raise IOError("Fail to create recording file")

(_LOADING, _LOADED, _PLAYING, _PLAYED, _STOPPING, _STOPPED,
 _PAUSING, _PAUSED ) = range(1, 9)

_STATE_TAB = dict((gst.element_state_get_name(state), state)
                  for state in (gst.STATE_NULL, gst.STATE_READY, gst.STATE_PAUSED,
                                gst.STATE_PLAYING, gst.STATE_VOID_PENDING))
state2str = gst.element_state_get_name
def str2state(skey):
  return _STATE_TAB.get(skey.upper())

_STATE_CHANGE_TAB = {gst.STATE_CHANGE_SUCCESS:"SUCCESS",
                     gst.STATE_CHANGE_ASYNC:"ASYNC",
                     gst.STATE_CHANGE_FAILURE:"FAILURE",
                     gst.STATE_CHANGE_NO_PREROLL:"PREROLL"}
def state_change2str(v):
  return _STATE_CHANGE_TAB.get(v, "UNKNOWN")
  
class CLIPlayer(object):

  def __init__(self, cmdqueue):
    self.dispatch_table = {
      "load":self.load_command, "quit":self.quit, 
      "play":self.play_command, "stop":self.stop_command,
      "_pause":self.pause_command, "_resume":self.resume_command,
      "pause":self.toggle_pause, "replay":self.replay_command,
      "rec":self.toggle_record, "gain":self.gain,
      "skip":self.skip_command, "jump":self.jump_command,
      "load-http":self.load_http,
      "load-shoutcast":self.load_shoutcast,
      "state":self.state_command, "info":self.info,
      "error":self.error_command, 
      "raise":self.raise_command, # for debug
      "warning":self.warning_command, # for debug
      }

    self.cmdqueue = cmdqueue
    # playmode _STOPPED|_PLAYING|_PAUSED
    self.requests = set()
    self.recfile_templ = FileTempl("~/.gaplay/rec%Y-%m-%d.wav")
    self.paused = False
    self.paused_pos = -1
    self.asink_org = None

    self.player = gst.element_factory_make("playbin2", "player")
    self.player.set_property("video-sink", 
                             gst.element_factory_make("fakesink", "fakevideo"))
    self.player.set_property("flags", 0x0012) # soft-volume+audio, not video and text
    ##self.player.set_property("flags", 0x0016) # soft-volume+text+audio, not video

    self.recsink = self.new_recsink()
    self.fsink = self.recsink.get_by_name("fsink")

    bus = self.player.get_bus()
    bus.add_signal_watch()
    bus.connect("message", self.on_message)

  def new_recsink(self, bit_depth=None):
    '''bit_depth -- None|16|24|32  None: system default'''
    tee = gst.element_factory_make("tee")
    queue_a = gst.element_factory_make("queue", "queue-a")
    queue_f = gst.element_factory_make("queue", "queue-f")
    fsink = gst.element_factory_make("filesink", "fsink")
    asink = gst.element_factory_make("autoaudiosink", "asink")
    encoder = gst.element_factory_make("wavenc")
    (wavfilter, aconverter) = (None, None)
    if bit_depth:
      caps = gst.Caps("audio/x-raw-int, depth=%d" % bit_depth)
      # caps = gst.Caps("audio/x-raw-float, depth=32")
      wavfilter = gst.element_factory_make("capsfilter", "wavfilter")
      wavfilter.set_property("caps", caps)
      # Require `audioconvert' for convert 'audio/x-raw-float, depth=32'
      # to 'audio/x-raw-int, depth=16or24'
      aconverter = gst.element_factory_make("audioconvert")
      
    recsink = gst.Bin("record-sink")
    recsink.add(tee, queue_f, queue_a, encoder, fsink, asink)
    if wavfilter:
      recsink.add(wavfilter)
      recsink.add(aconverter)

    pad_a = tee.get_request_pad('src%d')
    pad_a.link(queue_a.get_pad("sink"))
    gst.element_link_many(queue_a, asink)

    pad_f = tee.get_request_pad('src%d')
    pad_f.link(queue_f.get_pad("sink"))
    if wavfilter:
      gst.element_link_many(queue_f, aconverter, wavfilter, encoder, fsink)
    else:
      gst.element_link_many(queue_f, encoder, fsink)
      # gst.element_link_many(queue_f,  fsink) #-> NG

    pad_sink = tee.get_pad("sink")
    ghostpad = gst.GhostPad("sink", pad_sink)
    recsink.add_pad(ghostpad)
    return recsink
    
  # If failed or cannot get_state (only strict=True) then retruns None
  def get_state_list(self, tmout=mm2nano(500), strict=True):
    stlist = self.player.get_state( timeout=tmout)
    if stlist[0] == gst.STATE_CHANGE_FAILURE: return None
    if strict and (stlist[0] == gst.STATE_CHANGE_ASYNC):
      return None
    return stlist[1:]

  def has_state(self, state, tmout=mm2nano(500), strict=True):
    stlist = self.get_state_list(tmout, strict)
    if stlist is None: return False
    return state in stlist

  def query_duration(self, fallback=None):
    try: 
      return self.player.query_duration(gst.FORMAT_TIME, None)[0]
    except Exception: # gst.QueryError, IndexError, TypeError
      _puts("fail in query_duration")
      return fallback

  def query_position(self, fallback=None):
    try: 
      return self.player.query_position(gst.FORMAT_TIME, None)[0]
    except Exception: # gst.QueryError, IndexError, TypeError
      _puts("fail in query_position")
      return fallback

  def recfile(self):
    return self.recfile_templ.nextfile()

  def is_recording(self):
    return self.player.get_property("audio-sink") == self.recsink

  def update_recfile(self):
    rfile = self.recfile()
    self.fsink.set_property("location", rfile)
    return rfile

  def close_recfile(self):
    location = self.fsink.get_property("location")
    self.fsink.set_property("location", None)
    return location

  def load_command(self, args=[]):
    filepath = args and args[0]
    if not filepath:
      err_resp("usage: load URL|FILEPATH")
      return
    if match_uri(filepath): uri = filepath
    else:
      # when filename was specified
      abspath = os.path.abspath( os.path.expanduser(filepath) )
      if not os.path.isfile(abspath):
        err_resp("No such file - %s" % filepath)
        return
      uri = "file://" + urllib.pathname2url(abspath)
    # self.player.set_state(gst.STATE_NULL) # no need (play->stop)
    self.requests.add(_LOADING)
    self.requests.add(_PLAYING)
    if not self.play(uri):
      self.requests.discard(_LOADING)
      self.requests.discard(_PLAYING)

  def play_command(self, args=[]):
    self.requests.add(_PLAYING)
    if not self.play():
      self.requests.discard(_PLAYING)

  # bug? (in os-x)
  #  set_state(STATE_NULL -> STATE_PLAYING) returns volume-value to 1.0 
  def play_unchange_volume(self):
    vol = self.player.get_property("volume")
    if vol is not None: self.player.set_property("volume", vol)
    self.player.set_state(gst.STATE_PLAYING)

  def play(self, uri=None):
    self.stop()
    if uri:
      self.player.set_property("uri", uri)
      if self.player.get_property("uri") is None:
        _puts("uri is not set soon") 
    if self.is_recording(): 
      f = self.update_recfile()
      resp("REC", "start", f)
    # self.player.set_state(gst.STATE_PLAYING)
    self.play_unchange_volume()
    return True
    
  def stop_command(self, args=[]):
    if self.stop(): resp("STOP")

  def stop(self):
    (self.paused, self.paused_pos) = (False, -1)
    self.player.set_state(gst.STATE_NULL)
    if self.is_recording():
      f = self.close_recfile()
      if f: resp("REC", "end", f)
    return True
      
  def replay_command(self, args=[]):
    self.stop_command(args)
    self.play_command(args)
    # Suppress `Warning: gsignal.c:2576: instance has no handler with id ...'
    time.sleep(0.1)

  def pause_command(self, args=[]):
    self.requests.add(_PAUSING)
    if not self.pause():
      self.requests.discard(_PAUSING)

  def pause(self):
    if not self.has_state(gst.STATE_PLAYING):
      wrn_resp("Fail to pause - not playing")
      return False
    self.paused = True
    if self.query_duration(-1) > 0 :
      self.paused_pos = self.query_position(-1)
    else: self.paused_pos = -1

    if self.is_recording():
      self.player.set_state(gst.STATE_NULL)
      f = self.close_recfile()
      if f: resp("REC", "end", f)
    else:
      ret = self.player.set_state(gst.STATE_PAUSED)
      if ret == gst.STATE_CHANGE_ASYNC:
        _puts("Return STATE_CHANGE_ASYNC")
    return True

  def resume_command(self, args=[]):
    self.requests.add(_PLAYING)
    if not self.resume():
      self.requests.discard(_PLAYING)

  def resume(self):
    self.paused = False
    if self.has_state(gst.STATE_PLAYING):
      wrn_resp("Fail to resume - already playing")
      return False
    if self.has_state(gst.STATE_PAUSED):
      self.paused_pos = -1
      # not recording before paused
      if self.is_recording():
        err_resp("programing bug, will stop")
        self.stop()
        return False
      self.player.set_state(gst.STATE_PLAYING)
      return True
    else:
      if not self.has_state(gst.STATE_NULL):
        wrn_resp("Has not NULL state and PAUSED state")
      if self.is_recording():
        f = self.update_recfile()
        resp("REC", "start", f)
      if self.paused_pos > 0:
        self.player.set_state(gst.STATE_PAUSED)
        time.sleep(0.2) # Fix-me MADA
        self.player.seek_simple(gst.FORMAT_TIME, gst.SEEK_FLAG_FLUSH,
                                self.paused_pos)
      self.paused_pos = -1
      #self.player.set_state(gst.STATE_PLAYING)
      self.play_unchange_volume()
      return True

  def toggle_pause(self, args=[]):
    stlist = (self.get_state_list() or [])
    if gst.STATE_PLAYING in stlist:
      # will pause
      if self.paused: wrn_resp("Duplicated pause command")
      if _PAUSING in self.requests: wrn_resp("Already pausing")

      self.paused = True
      if self.query_duration(-1) > 0 :
        self.paused_pos = self.query_position(-1)
      else: self.paused_pos = -1

      self.requests.add(_PAUSING)
      if self.is_recording():
        self.player.set_state(gst.STATE_NULL)
        f = self.close_recfile()
        if f: resp("REC", "end", f)
      else:
        ret = self.player.set_state(gst.STATE_PAUSED)
        if ret == gst.STATE_CHANGE_ASYNC:
          wrn_resp("set_state returns STATE_CHANGE_ASYNC")
      return True

    elif gst.STATE_PAUSED in stlist:
      if _PLAYING in self.requests: wrn_resp("Already has playing-request")
      # will resume play and not recording
      (self.paused, self.paused_pos ) = (False , -1)
      # not recording before paused
      if self.is_recording():
        err_resp("programing bug, will stop")
        self.stop()
        return False
      self.requests.add(_PLAYING)
      self.player.set_state(gst.STATE_PLAYING)
      return True

    else:
      if not gst.STATE_NULL in stlist: # When cannot gst.get_state
        wrn_resp("player has not NULL or PAUSED or PLAYING state")
      if _PLAYING in self.requests: wrn_resp("Already has playing-request")
      # will resume to play after recording-pause or after stop
      pos = self.paused_pos
      (self.paused, self.paused_pos ) = (False , -1)

      if self.is_recording():
        f = self.update_recfile()
        resp("REC", "start", f)

      if pos > 0: # seek to just a paused positon
        self.player.set_state(gst.STATE_PAUSED)
        time.sleep(0.2) # Fix-me MADA
        self.player.seek_simple(gst.FORMAT_TIME, gst.SEEK_FLAG_FLUSH, pos)
      self.requests.add(_PLAYING)
      #self.player.set_state(gst.STATE_PLAYING)
      self.play_unchange_volume()
      return True
      
  def toggle_record(self, args=[]):
    pos = -1
    playing = self.has_state(gst.STATE_PLAYING)
    if playing:
      if self.query_duration(-1) > 0:
        pos = self.query_position(-1)

    self.player.set_state(gst.STATE_NULL)
    if self.is_recording():
      f = self.close_recfile()
      if f: resp("REC", "end", f)
      asink = self.asink_org
      if not asink:
        if _isdebug: wrn_resp("Fail original audio sink, use `autoaudiosink'")
        asink = gst.element_factory_make("autoaudiosink", "asink-org")
      self.player.set_property("audio-sink", asink)
      _puts("Stop recording")
    else:
      f = self.update_recfile()
      self.player.set_property("audio-sink", self.recsink)
      resp("REC", "start", f)
      
    if playing:
      if pos >= 0:
        self.player.set_state(gst.STATE_PAUSED)
        time.sleep(0.2) # Fix-me MADA
        self.player.seek_simple(gst.FORMAT_TIME, gst.SEEK_FLAG_FLUSH, pos)
      #self.player.set_state(gst.STATE_PLAYING)
      self.play_unchange_volume()

  def quit(self, args=[]):
    self.stop_command()
    time.sleep(0.2) # no need
    loop.quit()
    
  def gain(self, args=[]):
    if args:
      self.player.set_property("volume", float(args[0]))
    resp("GAIN", self.player.get_property("volume"))
    
  def show_state(self): # for debug
    states = self.player.get_state( timeout=mm2nano(500))
    if states:
      resp("STATE", state_change2str(states[0]),
           tuple(state2str(s) for s in states[1:]))
    else: resp("STATE", "none")

  def info(self, args=[]):
    uri = self.player.get_property("uri")
    volume = self.player.get_property("volume")
    resp("INFO", "uri=%s gain=%s" % ( (uri or "none"), volume))
    if _isdebug:
      self.show_state()
      resp("REQS", tuple(self.requests))

  def seek(self, nsec, incremental=False):
    if self.is_recording():
      wrn_resp("cannot seek when recording")
      return
    if not self.has_state(gst.STATE_NULL):
      (dur, pos) = (self.query_duration(-1), self.query_position(-1))
      if dur > 0 and pos >= 0 :
        if incremental: nsec = pos + nsec
        newpos = min(dur, max(0, nsec))
        if self.player.seek_simple(gst.FORMAT_TIME, gst.SEEK_FLAG_FLUSH, newpos):
          resp("SEEK", "%s/%s" % (sec2str( nano2sec(newpos) ),
                                  sec2str( nano2sec(dur))))
        else:
          err_resp("fail to seek")
      else:
        wrn_resp("cannot seek")
    else:
      wrn_resp("fail to seek - not playing")

  def skip_command(self, args=[]):
    sec = args and int( args[0] )
    if not sec:
      err_resp("usage: skip SEC")
      return
    return self.seek(sec * 1000000000, True)

  def jump_command(self, args=[]):
    sec = args and int( args[0] )
    if (not sec) and (sec != 0):
      err_resp("usage: jump SEC")
      return
    return self.seek(sec * 1000000000, False)
      
  def raise_command(self, args=[]):  # for debug
    raise Exception(*args)

  def error_command(self, args=[]): 
    err_resp(*args)

  def warning_command(self, args=[]): 
    wrn_resp(*args)

  def state_command(self, args=[]):  # for debug
    skey = args and args[0]
    if skey:
      state = str2state(skey)
      if state:
        _puts("begin set_state %s", skey)
        ret = self.player.set_state(state)
        _puts("end set_state %s", skey)
        if ret == gst.STATE_CHANGE_ASYNC:
          _puts("Return STATE_CHANGE_ASYNC")
      else: err_resp("No state key - %s" % skey)
    self.show_state()

  def load_http(self, args=[]):
    uri = args and args[0]
    if not uri:
      err_resp("usage: load-http URL")
      return
    if match_http(uri):
      plsinfo = get_playlist(uri, False, timeout=LOAD_PLAYLIST_TIMEOUT)
      if isinstance(plsinfo, dict):
        resp("PLAYLIST-BEGIN", plsinfo.get("_type","-"), uri)
        for num, entry in enumerate(plsinfo.get("_entries", [])):
          num = num + 1
          if entry.get("file"): resp(">", num, "path", entry.get("file",""))
          if entry.get("length"): resp(">", num, "duration %d" % entry.get("length",-1))
          if entry.get("title"): resp(">", num, "title", entry.get("title",""))
        resp("PLAYLIST-END")
        return
    self.load_command(args)

  def load_shoutcast(self, args=[]):
    (entrynum, plspath) = args[0].split(None,1)
    entrynum = int(entrynum)
    if not match_uri(plspath): # convert to abspath when localpath 
      plspath = os.path.abspath( os.path.expanduser(plspath) )

    # Get playlist contents
    plsinfo = get_playlist(plspath, True, timeout=LOAD_PLAYLIST_TIMEOUT)
    entries = plsinfo.get("_entries")
    if not entries:
      wrn_resp("playlist has no entry - %s" % plspath)
      return
    # Select playlist entry
    if entrynum == 0:
      entrynum = random.randrange(1,len(entries)+1)
    elif entrynum > 0:
      entrynum = min(entrynum, len(entries))
    else:
      entrynum = len(entries)
    entry = entries[entrynum - 1]

    loadpath = entry.get("file")
    if not loadpath:
      wrn_resp("playlist entry has not `file' attribute")
      return
    if match_uri2(plspath): # http|https|ftp playlist
      if is_localpath(loadpath):
        wrn_resp("remote playlist entry has local-path - %s" % loadpath)
        return
    elif not match_uri(plspath): #localfile playlist except file:
      if not match_uri(loadpath):
        loadpath = os.path.join( os.path.dirname(plspath), loadpath)
    _puts("playlist loadpath=%s", loadpath)
    # playlist response
    if match_uri(plspath): plsuri = plspath
    else:
      plsuri= "file://" + urllib.pathname2url(plspath)
    resp("SHOUTCAST", plsuri, entrynum,
         entry.get("length",-1), entry.get("title",""))
    # load
    self.load_command([loadpath])

  def make_duration_watcher(self):
    _oldvalues = [-1, -1]
    def _output():
      if self.has_state(gst.STATE_PLAYING):
        (dur, pos) = (self.query_duration(None), self.query_position(None))
        if (dur is not None) and (pos is not None):
          if dur >= 0:
            dur = nano2sec(dur)
          else: dur = -1
          if pos >= 0:
            pos = nano2sec(pos)
          else: pos = -1
          if (pos != _oldvalues[1]) or (dur != _oldvalues[0]):
            (_oldvalues[0], _oldvalues[1]) = (dur, pos)
            resp("T", "%s/%s" % (-1 if pos < 0 else sec2str(pos),
                                  -1 if dur < 0 else sec2str(dur)))
      elif self.has_state(gst.STATE_NULL):
        (_oldvalues[0], _oldvalues[1]) = (-1, -1)
      return True
    return _output
    
  def get_command(self):
    "Get command from cmdqueue, and ignore repeated command"
    def skip_with_addvalue(cmd, next_cmdlist):
      nextcmd = next_cmdlist[0]
      if cmd[0] == nextcmd[0]:
        try:
          newvalue = str( long(cmd[1]) + long(nextcmd[1]) )
        except (IndexError, ValueError): return False
        nextcmd[1] = newvalue # update! nextcmd[1]
        return True
      return False

    with self.cmdqueue.lock:
      cmdlist = self.cmdqueue.cmdlist
      if _isdebug and cmdlist:  # for debug
        print "CMDLIST=", self.cmdqueue.cmdlist # for debug
      while cmdlist:
        cmd = cmdlist.pop(0)
        if not cmdlist: return cmd
        elif cmd[0] in ("pause", "rec", "replay"):
          if cmd[0] == cmdlist[0][0] :
            if cmd[0] != "replay":
              # skip this and next one
              cmdlist.pop(0)
          else: return cmd
        elif cmd[0] == "skip":
          if skip_with_addvalue(cmd, cmdlist):
            continue
          return cmd
        else: return cmd
      return None

  def dispatch_command(self):
    try:
      #cmdline = self.cmdqueue.get()
      cmdline = self.get_command()
      if cmdline:
        _puts("dispatch_command cmdline=%s thread=%s", cmdline, threading.currentThread())
        command = cmdline[0]
        args = cmdline[1:]
        cmdop = self.dispatch_table.get(command)
        try:
          if cmdop: cmdop(args)
          else:
            err_resp("Illegal command - %s" % command)
        except Exception , exc:
          self.requests.clear()
          tblist = traceback.format_tb(sys.exc_info()[2])
          if _isdebug:
            for tbstr in tblist: sys.stdout.write(tbstr)
            sys.stdout.flush()
          err_resp("fail to dispatch_command: %s - %s" % (exc, cmdline))
      return True
    except BaseException, err: 
      if not isinstance(err, KeyboardInterrupt):
        if _isdebug:
          tblist = traceback.format_tb(sys.exc_info()[2])
          for tbstr in tblist: sys.stdout.write(tbstr)
          sys.stdout.flush()
      self.quit()

  def response_by_state(self, ostate, nstate):
    _puts("response_by_state req=%s", self.requests)
    if nstate == gst.STATE_PLAYING:
      if _PLAYING in self.requests:
        resp("PLAY")
        self.requests.discard(_PLAYING)
      if _LOADING in self.requests:
        uri = self.player.get_property("uri")
        resp("LOAD", uri)
        self.requests.discard(_LOADING)
    elif nstate == gst.STATE_PAUSED:
      if _PAUSING in self.requests:
        resp("PAUSE")
        self.requests.discard(_PAUSING)
    elif nstate == gst.STATE_NULL: # Not coming here
      if _PAUSING in self.requests:
        resp("PAUSE")
        self.requests.discard(_PAUSING)
      if _STOPPING in self.requests:
        resp("STOP")
        self.requests.discard(_STOPPING)

  def print_caps(self):
    "for debug"
    asink = self.player.get_property("audio-sink")
    if not asink: return
    for pad in asink.sink_pads():
      # capinfo = pad.get_caps()[0]
      caps = pad.get_negotiated_caps()
      if caps is None: continue
      print "caps=",caps, "type=", type(caps), "len=",len(caps)
      capinfo = caps[0]
      print "CAP structure_name=", capinfo.get_name(), "keys=", capinfo.keys()
      if capinfo.get_name().startswith("audio/"):
        rate = capinfo["rate"] if capinfo.has_key("rate") else None
        ch = capinfo["channels"] if capinfo.has_key("channels") else None
        w = capinfo["width"] if capinfo.has_key("width") else None
        d = capinfo["depth"] if capinfo.has_key("depth") else None
        print "CAP width=",w, "depth=",d,"rate=",rate, "channels=", ch

  def report_caps(self, sink):
    for pad in sink.sink_pads():
      caps = pad.get_negotiated_caps()
      if not caps:  continue
      capinfo = caps[0]
      #print "CAP structure_name=", capinfo.get_name(), "keys=", capinfo.keys()
      resp("CAP", capinfo.get_name(), " ".join(
          ("%s=%s" % (k, capinfo[k]) for k in capinfo.keys()) ))

  def test_image(self, buf): # debug function for capture image
    caps = buf.get_caps()
    for cap in caps:
      _puts("image cap %s %s", cap.get_name(),
            " ".join( ("%s=%s" % (k, cap[k]) for k in cap.keys()))  )
    with open("/tmp/gaplay-test.img","wb") as f:
      f.write(buf.data)

  def on_message(self, bus, message):
    try:
      if threading.currentThread() != mainloop_thread :
        err_resp("on_message is not run main thread -%s" % threading.currentThread())
      mtype= message.type
      if mtype== gst.MESSAGE_EOS:
        uri = self.player.get_property("uri")
        self.player.set_state(gst.STATE_NULL)
        resp("STOP")
        resp("EOS", uri)
      elif mtype== gst.MESSAGE_TAG:
        srctype = "-"
        if message.src:
          # video-bitrate or audio-bitrate? (fix-me ad hoc!)
          klass = message.src.get_factory().get_klass().lower()
          # print "srcname=", message.src.get_name(), " klass=",klass # debug
          if "audio" in klass: srctype = "A"
          elif "video" in klass: srctype = "V"
        tags = message.parse_tag()
        for k in tags.keys():
          v = tags[k]
          if isinstance(v, (basestring, int, float, long, bool, gst.Date)):
            resp("TAG", srctype, "%s=%s" % (k, v))
          else:
            # if _isdebug: # image test
            #  if k == "image" and isinstance(v, gst.Buffer): self.test_image(v)
            resp("TAG", srctype, "%s=%s" % (k, type(v)))
      elif mtype == gst.MESSAGE_STATE_CHANGED:
        (o_state, n_state, pending) = message.parse_state_changed()
        (old, new, ps) = ( gst.element_state_get_name(o_state),
                           gst.element_state_get_name(n_state),
                           gst.element_state_get_name(pending))
        # _puts("State changed %s => %s pending:%s",old, new, ps)
        # _puts("audio-sink %s", self.player.get_property("audio-sink"))
        if not self.asink_org:
          # Set original audiosink
          asink = self.player.get_property("audio-sink")
          if asink and (asink != self.recsink):
            _puts("Set original asink to %s", asink)
            self.asink_org = asink
        elif (o_state == gst.STATE_READY) and (n_state == gst.STATE_PAUSED):
          # Report audiosink negotiated capacities
          self.report_caps(self.asink_org)

        if self.requests:
          self.response_by_state(o_state, n_state)

      elif mtype== gst.MESSAGE_WARNING:
        err, debug = message.parse_warning()
        if _isdebug: wrn_resp("%s - %s" % (err, debug))
        else: wrn_resp(err)
      elif mtype== gst.MESSAGE_ERROR:
        self.player.set_state(gst.STATE_NULL)
        err, debug = message.parse_error()
        if _isdebug: err_resp("%s - %s" % (err, debug))
        else: err_resp(err)
        self.stop()
        resp("STOP")
      else:
        _puts("On message: Unsupported message type %s", mtype)
        _puts("  src %s", message.src)
        struct = message.structure
        if struct is not None:
          _puts("  structure:")
          for k in struct.keys():
            _puts("    key=%s value=%s", k , struct[k])
    except Exception , exc:
      err_resp("on_message - %s" % exc)

if sys.version_info[0] >= 2 and sys.version_info[1] >= 6:
  _urlopen = urllib2.urlopen
else:
  # when python 2.5 , ignore timeout argument
  _urlopen = lambda *args,**kwd: urllib2.urlopen(*args[:2])

# raise urllib2.URLError < IOError
def get_playlist(path, http_force=False, timeout=30):
  r'''Read pls or m3u playlist , return following dictionary 
  {"_type":"m3u|pls", 
   "_entries":{["file":file-name, "length":duration, "title":title]...},
   "numberofentries":Number-Of-Entries }'''
  path = path.strip()
  filetype = None
  m = re.match(r'''(http|https|ftp)://''', path, re.I)
  if m:
    proto = m.group(1).lower()
    f = None
    try:
      # f = urllib2.urlopen(path, timeout=timeout) 
      f = _urlopen(path, timeout=timeout) 
      ctype = f.info().getheader("content-type","").lower().split(";")
      if ctype[0] == "audio/x-scpls": filetype = "pls"
      elif ctype[0] == "audio/x-mpegurl": filetype = "m3u"
      if filetype or http_force or proto == "ftp":
        return read_playlist(f, filetype, path)
      else:
        return None
    finally:
      if f: f.close()
  else:
    path = os.path.abspath( os.path.expanduser(path) )
    (_, ext) = os.path.splitext(path)
    ext = ext.lower()
    if ext == ".pls": filetype = "pls"
    elif ext == ".m3u": filetype = "m3u"
    with open(path, "r") as f:
      return read_playlist(f, filetype, path)

def read_playlist(f, filetype, path):
  line = "\n"
  if not filetype:
    # read first line
    while line and line.strip() == "": line = f.readline(8192)
    if not line: return(dict())
    if line.strip() == "": return(dict())
    if line.strip().lower() == "[playlist]":
      filetype = "pls"
    else:
      filetype = "m3u" # ??
  
  if filetype == "pls": return read_pls(f)
  else: return read_m3u(f, line)
    
def read_pls(f, unread=None):
  r'''Read pls, return following dictionary 
  {"_type": "pls",
   "_entries": [{"file":file-name, "length":duration, "title":title}...],
   "numberofentries": Number-Of-Entries, 
   "version": versin-number-string }'''

  rchop = re.compile( r'[\n\r]+\Z' )
  ritem = re.compile( r'''(file|title|length)(\d+)''' )
  plsinfo = dict()
  entries = dict()
  def parse(line):
    # binary check??
    if (len(line) > 1024) and ("\x00" in line): raise ValueError
    if line.strip() == "": return
    datas = rchop.sub("", line).split("=")
    if len(datas) <= 1: return
    key=datas[0].lower().strip()
    m = ritem.match(key)
    if m:
      vkey = m.group(1)
      nkey = int(m.group(2))
      val = entries.get(nkey, dict())
      data = "=".join(datas[1:])
      try:
        if vkey == "length": 
          data = long(data)
        val[vkey] = data
        entries[nkey] = val
      except:pass
    elif key == "numberofentries":
      try:  plsinfo[key] = int(datas[1])
      except ValueError:pass
    else:
      plsinfo[key] = "=".join(datas[1:])
  
  try:
    if unread: parse(unread)
    for line in f: parse(line)
  
    plsinfo["_entries"] = [entries[k] for k in sorted(entries.keys())]
    plsinfo["_type"] = "pls"
    return plsinfo

  except ValueError:
    _puts("Not pls file - read_m3u")
    return dict()

def read_m3u(f, unread=None):
  r'''Read m3u, return following dictionary 
  {"_type": "m3u",
   "_entries":[{"file":file-name, "length":duration, "title":title}...],
   "numberofentries":Number-Of-Entries }'''
  rchop = re.compile( r'[\n\r]+\Z' )
  entries = list()
  extinf = dict()
  def parse(line):
    # binary check??
    if (len(line) > 1024) and ("\x00" in line): raise ValueError
    if line.strip() == "": return
    line = rchop.sub("", line)
    if line[0] == "#":
      m = re.match("#extinf:", line, re.I)
      if m:
        datas = line[m.end():].split(",", 1)
        try:
          extinf["length"] = long(datas[0])
        except:pass
        if len(datas) > 1: extinf["title"] = datas[1]
    else:
      extinf["file"] = line
      entries.append(dict(extinf))
      extinf.clear()

  try:
    if unread: parse(unread)
    for line in f: parse(line)
    return {"_type":"m3u", "_entries":entries, "numberofentries":len(entries)}
  except ValueError:
    _puts("Not m3u file - read_m3u")
    return dict()

if __name__ == "__main__":
  signal.signal(signal.SIGTSTP, signal.SIG_IGN) # disable C-Z
  #_puts("main thread=%s", threading.currentThread()) # debug
  cmdqueue = CommandQueue()
  player = CLIPlayer(cmdqueue)
  read_thread = threading.Thread(target=read_command, args=(cmdqueue,))
  read_thread.daemon = True
  read_thread.start()

  gobject.threads_init()
  mainloop_thread = threading.currentThread()
  gobject.idle_add(player.dispatch_command)
  gobject.timeout_add(500, player.make_duration_watcher())
  # loop = glib.MainLoop()
  loop = gobject.MainLoop()

  def killself(*args):
    player.quit()
    _puts("SIGHUP")
    resp("QUIT")
    exit()
  signal.signal(signal.SIGHUP, killself) # kill -HUP

  resp("READY", _program, "version:%s" % _version, _copyright)
  try:
    loop.run()
  except BaseException, err:
    player.quit()
    if isinstance(err, KeyboardInterrupt):
      err_resp("keyboard interrupt") # catch SIGINT
    else:
      tblist = traceback.format_tb(sys.exc_info()[2])
      if _isdebug:
        for tbstr in tblist: sys.stdout.write(tbstr)
        sys.stdout.flush()
      err_resp("%s" % exc)

  resp("QUIT")
  exit()
