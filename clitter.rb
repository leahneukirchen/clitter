#!/usr/bin/env ruby
# -*- ruby -*-

# clitter twitter client

Thread.abort_on_exception = true

require 'json'
require 'open-uri'
require 'pp'
require 'time'
require 'digest/md5'
require 'tempfile'

require 'ffi'
module Setlocale
  extend FFI::Library
  ffi_lib('c')
  LC_ALL = 6
  attach_function :setlocale, [:int, :string], :uint
end
Setlocale.setlocale(Setlocale::LC_ALL, "")

ENV["RUBY_FFI_NCURSES_LIB"] = "ncursesw"
require 'ffi-ncurses'
require 'ffi-ncurses/keydefs'
('A'..'Z').each { |c| NCurses.const_set "KEY_CTRL_#{c}", c[0]-?A+1 }

Curses = NCurses
Curses.extend FFI::NCurses

module Curses
  A_BOLD = FFI::NCurses::A_BOLD
  KEY_F1 = NCurses::KEY_F0+1
  KEY_F2 = NCurses::KEY_F0+2
  KEY_F3 = NCurses::KEY_F0+3
  KEY_F4 = NCurses::KEY_F0+4
  KEY_F5 = NCurses::KEY_F0+5
  KEY_F6 = NCurses::KEY_F0+6
  KEY_F7 = NCurses::KEY_F0+7
  KEY_F8 = NCurses::KEY_F0+8
  KEY_F9 = NCurses::KEY_F0+9
  KEY_F10 = NCurses::KEY_F0+10

  def self.cols
    getmaxx($stdscr)
  end

  def self.lines
    getmaxy($stdscr)
  end

  def self.setpos(y, x)
    move(y, x)
  end

  def addstr(s)
    waddnstr($stdscr, s, s.size)
  end
end

COUNT = 20

begin
  load "~/.twicl"
rescue LoadError
  abort <<ERR
No ~/.twicl found, please create one with these contents:

  $auth = ["your twitter username", "your twitter password"]

ERR
end

$last_id = {}

def fetch(type, url)
  url += "?count=#{COUNT}"
  url += "&since_id=#{$last_id[url]}"  if $last_id[url]

  begin
    posts = JSON.load(open(url, :http_basic_authentication => $auth))
  rescue => e
    if e.message =~ /400 Bad Request/
      $status = "API limit reached."
      abort $status  unless $running
    else
      $status = "!> #{e.message}"
    end
  rescue Timeout::Error
    # ignore
  end

  posts.each { |post|
    post["created_at"] = Time.parse(post["created_at"])
  }
  $last_id[url] = posts.map { |post| post["id"] }.max || $last_id[url]
  
  ($tweets[type] ||= []).concat posts
  $tweets[type] = $tweets[type].sort_by { |p| p["created_at"] }.reverse
end

def update_home
end

def post(string, auth)
  res = Net::HTTP.post_form(
    URI.parse("http://#{auth * ":"}@api.twitter.com/1/statuses/update.json"),
    "status" => string)
  JSON.parse(res.body)["id"]
end

def display(post, i, y)
  width = Curses.cols - 3
  flowed = post["text"].gsub(/(.{1,#{width}})( +|$\n?)|(.{1,#{width}})/, "\\1\\3\n").gsub(/^\s*/, '  ')

  if y > 0
  Curses.setpos(y, 0)
  
  Curses.attron(Curses::A_BOLD)
  Curses.standout  if i == $sel
  Curses.addstr("%s (%s)%s:\n" % [post["user"] ? post["user"]["screen_name"] :
                                  post["sender_screen_name"],
                                  reltime(post["created_at"]),
                                  post["favorited"] ? " (***)" : ""])
  Curses.standend  if i == $sel
  Curses.attroff(Curses::A_BOLD)

  Curses.addstr(flowed)
  end

  flowed.count("\n") + 1
end

def reltime(time, other=Time.now)
  s = (other - time)
  d, s = s.divmod(60*60*24)
  h, s = s.divmod(60*60)
  m, s = s.divmod(60)
  
  return "%dd" % d  if d > 0
  return "%dh" % h  if h > 0
  return "%dm" % m  if m > 0
  return "%ds" % s
end

def draw
  return  unless $run

  Curses.erase
  Curses.setpos(0, 0)
  Curses.attron(Curses::A_BOLD)
  Curses.addstr($title)
  Curses.attroff(Curses::A_BOLD)

  y = 2
  maxlines = Curses.lines - 4

  skip = $sel
  have = maxlines-10
  while have > 0 && skip > 0
    have -= display($tweets[$view][skip], 0, -1)  rescue 0
    skip -= 1
  end

  $tweets[$view].each_with_index { |post, i|
    next  if i < skip
    y += display(post, i, y)
    break  if y > maxlines
  }

  Curses.setpos(Curses.lines-1, 0)
  Curses.addstr($status)

  Curses.refresh
end


def apply_killfile
  $tweets.each { |_, posts|
    posts.delete_if { |post|
      matched = false
      kill = false
      
      $killfile.reverse_each { |line|
        case line
        when %r{^(.*?)/(.*)/([ic+]*)$}
          urx = Regexp.new($1, 0, 'u')
          kill = !$3.include?("+")
          trx = Regexp.new($2, $3 =~ /[ic]/ ? Regexp::IGNORECASE : 0, 'u')
          if ((post["sender_screen_name"] || post["user"]["screen_name"]) =~ urx &&
              post["text"] =~ trx)
            matched = true
            break
          end
        end
      }
      
      matched && kill
    }
  }
end

def refresh
  prev_id = $tweets[$view][$sel]["id"]  rescue nil

  $status = "Updating"; draw
  fetch(:home, "http://api.twitter.com/1/statuses/home_timeline.json")
  $status = "Updating."; draw
  fetch(:replies, "http://api.twitter.com/1/statuses/replies.json")
  $status = "Updating.."; draw
  fetch(:direct, "http://api.twitter.com/1/direct_messages.json")
  $status = "Updating..."; draw
  fetch(:favorites, "http://api.twitter.com/1/favorites.json")
  $status = "Updating...."; draw

  $sel = 0
  while $sel < $tweets[$view].size
    break  if $tweets[$view][$sel]["id"] == prev_id
    $sel += 1
  end
  $sel = 0  if $sel > $tweets[$view].size

  apply_killfile

  $status = Time.now.strftime("Last refresh %H:%M.")
end

def post(msg="")
  Tempfile.open("clitter") { |text|
    text << msg
    text.close

    Curses.endwin
    system "vim", "-c", "start!", text.path
    Curses.clear
    draw
    Curses.refresh

    text.reopen(text.path)
    text.rewind
    post = text.read
    if post.empty? || post == msg
      $status = "Post canceled."
      nil
    else
      $status = "Posted."
      post
    end
  }
end

def load_killfile
  begin
    $killfile = File.read(File.expand_path("~/.clitter.kill"))
  rescue
    $killfile = []
  end
end

begin
  load_killfile

  $tweets = {}
  $sel = 0
  $view = :home
  refresh
  $title = "clitter - friends of #{$auth.first}"
  $status = "Started."

  $run = true

  $stdscr = Curses.initscr
  Curses.nonl
  Curses.cbreak
  Curses.raw
  Curses.noecho
  Curses.keypad($stdscr, 1)
  Curses.meta($stdscr, 1)
  Curses.halfdelay(10)              # or getch blocks

  Thread.new {
    while $run
      refresh
      sleep 120
#      $tweets[$view].unshift $tweets[$view].pop
    end
  }
  
  while $run
    draw
    
    case c = Curses.getch
    when ?1
      $title = "clitter - friends of #{$auth.first}"
      $view = :home
      $sel = 0
    when ?2
      $title = "clitter - replies to #{$auth.first}"
      $view = :replies
      $sel = 0
    when ?3
      $title = "clitter - direct messages to #{$auth.first}"
      $view = :direct
      $sel = 0
    when ?4
      $title = "clitter - favorites of #{$auth.first}"
      $view = :favorites
      $sel = 0

    when Curses::KEY_CTRL_L
      Curses.clear
      draw

    when Curses::KEY_CTRL_R, ?\s
      refresh
      Curses.clear
      draw

    when ?p, Curses::KEY_ENTER, ?\n, ?\r
      post
    when ?r
      post("@#{$tweets[$view][$sel]["user"]["screen_name"]} ")
    when ?R
      post("RT @%s %s" % [$tweets[$view][$sel]["user"]["screen_name"], $tweets[$sel]["text"]])
    when ?d
      post("d #{$tweets[$view][$sel]["user"]["screen_name"]} ")

    when ?K
      Curses.clear
      Curses.endwin
      system "vim", File.expand_path("~/.clitter.kill")
      load_killfile
      refresh
      Curses.clear
      draw
      $stdscr = Curses.initscr
      Curses.nonl
      Curses.cbreak
      Curses.raw
      Curses.noecho
      Curses.keypad($stdscr, 1)
      Curses.meta($stdscr, 1)
      Curses.refresh

    when Curses::KEY_UP
      $sel = [0, $sel-1].max
    when Curses::KEY_DOWN
      $sel = [$sel+1, $tweets[$view].size-1].min

    when Curses::KEY_DOWN
      $sel = ($sel+1) % $tweets[$view].size

    when Curses::KEY_CTRL_C, Curses::KEY_CTRL_D, ?q
      $run = false

    when -1
      # icky
      sleep 0.001
      Thread.pass

    end
  end

ensure
  Curses.endwin
  p $!  if $!
end
