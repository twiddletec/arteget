#!/usr/bin/env ruby
# arteget 
# Copyright 2008-2013 Rapha�l Rigo
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA

require 'pp'
require 'optparse'
require 'uri'
require 'json'
require 'libhttpclient'

LOG_ERROR = -1
LOG_QUIET = 0
LOG_NORMAL = 1
LOG_DEBUG = 2

$options = {:log => LOG_NORMAL, :lang => "fr", :qual => "hd", :subs => false}


def log(msg, level=LOG_NORMAL)
	puts msg if level <= $options[:log]
end

def error(msg)
	log(msg, LOG_ERROR)
end

def fatal(msg)
	error(msg)
	exit(1)
end

def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each { |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable? exe
    }
  end
  return nil
end

def print_usage
	puts "Usage : arteget [-v] [--qual=QUALITY] [--lang=LANG] --best[=NUM]|--top[=NUM]|URL|program"
	puts "\t\t--quiet\t\t\tonly error output"
	puts "\t-v\t--verbose\t\tdebug output"
	puts "\t-f\t--force\t\t\toverwrite destination file"
	puts "\t-o\t--output=filename\t\t\tfilename if downloading only one program"
	puts "\t-d\t--dest=directory\t\t\tdestination directory"
	puts "\t\t--subs\t\t\ttry do download subtitled version"
	puts "\t-q\t--qual=hd|md|sd|ld\tchoose quality, hd is default"
	puts "\t-l\t--lang=fr|de\t\tchoose language, german or french (default)"
	puts "\t-b\t--best [NUM]\t\tdownload the NUM (10 default) best rated programs"
	puts "\t-t\t--top [NUM]\t\tdownload the NUM (10 default) most viewed programs"
	puts "\tURL\t\t\t\tdownload the video on this page"
	puts "\tprogram\t\t\t\tdownload the latest available broadcasts of \"program\""
end

# Find videos in the given JSON array
def parse_json(progs)
	result = progs.map { |p| [p['url'], p['title'], p['desc']] }
	return result
end

# Basically gets the lists of programs in JSON format
# returns an array of arrays, containing 3 strings : [url, title, teaser]
def get_progs_urls(progname)
	log("Getting json")

	plus7 = $hc.get("/guide/#{$options[:lang]}/plus7.json").content
    plus7_j = JSON.parse(plus7)

	fatal("Cannot get program list JSON") if not plus7_j 

    vids = plus7_j["videos"]

	if $options[:best] then
		bestnum = $options[:best]
		log("Computing best #{bestnum}")
        ranked = vids.find_all { |v| v["video_rank"] != nil and v["video_rank"]  > 0 }
        ranked.sort! { |a, b| a["video_rank"] <=> b["video_rank"] }.reverse!
        pp ranked
        result = parse_json(ranked[0,bestnum])
	elsif $options[:top] then
		topnum = $options[:top]
		log("Computing top #{topnum}")
        vids.sort! { |a, b| a["video_views"][/^[0-9 ]+/].gsub(' ','').to_i <=> b["video_views"][/^[0-9 ]+/].gsub(' ', '').to_i }.reverse!
        result = parse_json(vids[0,topnum])
	else
        # We have a program name
        progs = vids.find_all {|p| p["title"].casecmp(progname) == 0 }
        if progs != nil and progs.length > 0 then
		    result = parse_json(progs) 
        end
	end
	fatal("Cannot find requested program(s)") if result == nil or result.length == 0
	return result
end

def dump_video(page_url, title, teaser)
    if title == "" and teaser == "" then
        log("Trying to get #{page_url}")
    else
        log("Trying to get #{title}, teaser : \"#{teaser}\"")
    end
	# ugly but the only way (?)
	vid_id = page_url[/\/([0-9]+-[0-9]+)\//,1]
	return error("No video id in URL") if not vid_id

	log("Getting video page")
	page_video = $hc.get(page_url).content
	videoref_url = page_video[/arte_vp_url="http:\/\/arte.tv(.*PLUS7.*\.json)"/,1]
	log(videoref_url, LOG_DEBUG) 
    if videoref_url == nil then
        error("Cannot find the video")
        return
    end

	log("Getting video description JSON")
	videoref_content = $hc.get(videoref_url).content
	log(videoref_content, LOG_DEBUG)
	vid_json = JSON.parse(videoref_content)

    # Fill metadata if needed
    if title == "" or teaser == "" then
        title = vid_json['videoJsonPlayer']['VTI']
        teaser = vid_json['videoJsonPlayer']['V7T']
        log(title+" : "+teaser)
    end

    ###
    # Some information :
    #   - quality is always "XX - res", where XX is HD/MD/SD/LD
    #   - mediaType can be "rtmp" or "" for direct HTTP download
    #   - versionProg can be '1' for native, '2' for the other langage and '8' for subbed
    ###
    good = vid_json['videoJsonPlayer']["VSR"].values.find_all do |v|
        v['quality'] =~ /^#{$options[:qual]}/i and
        v['mediaType'] == 'rtmp' and
        v['versionProg'] == ($options[:subs] ? '8' : '1')
    end

    # If we failed to find a subbed version, try normal
    if not good or good.length == 0 and $options[:subs] then 
        log("No subbed version ? Trying normal")
        good = vid_json['videoJsonPlayer']["VSR"].values.find_all do |v|
            v['quality'] =~ /^#{$options[:qual]}/i and
            v['mediaType'] == 'rtmp' and
            v['versionProg'] == '1'
        end
    end
    if good.length > 1 then
        log("Several version matching, downloading the first one")
    end
    good = good.first

    rtmp_url = good['streamer']+'mp4:'+good['url']
	if not rtmp_url then
		return error("No such quality")
	end
	log(rtmp_url, LOG_DEBUG)

    if $options[:dest] then
        filename = $options[:dest]+File::SEPARATOR
    else
        filename = ""
    end
	filename = filename + ($options[:filename] || vid_id+"_"+title.gsub(/[\/ "*:<>?|\\]/," ")+"_"+$options[:qual]+".flv")
	return log("Already downloaded") if File.exists?(filename) and not $options[:force]

	log("Dumping video : "+filename)
	log("rtmpdump -o #{filename} -r \"#{rtmp_url}\"", LOG_DEBUG)
	fork do 
		exec("rtmpdump", "-q", "-o", filename, "-r", rtmp_url)
	end

	Process.wait
	if $?.exited?
		case $?.exitstatus
			when 0 then
				log("Video successfully dumped")
			when 1 then
				return error("rtmpdump failed")
			when 2 then
				log("rtmpdump exited, trying to resume")
				exec("rtmpdump", "-e", "-q", "-o", "#{vid_id}.flv", "-r", rtmp_url)
		end
	end
end

begin 
	OptionParser.new do |opts|
		opts.on("--quiet") { |v| $options[:log] = LOG_QUIET }
		opts.on("--subs") {$options[:subs] = true }
		opts.on('-v', "--verbose") { |v| $options[:log] = LOG_DEBUG }
		opts.on('-f', "--force") { $options[:force] = true }
		opts.on('-b', "--best [NUM]") { |n| $options[:best] = n ? n.to_i : 10 }
		opts.on('-t', "--top [NUM]") { |n| $options[:top] = (n ? n.to_i : 10) }
		opts.on("-l", "--lang=LANG_ID") {|l| $options[:lang] = l }
		opts.on("-q", "--qual=QUAL") {|q| $options[:qual] = q }
		opts.on("-o", "--output=filename") {|f| $options[:filename] = f }
		opts.on("-d", "--dest=directory")  do |d|
            if not File.directory?(d)
                puts "Destination is not a directory"
                exit 1
            end
            $options[:dest] = d
        end
	end.parse!
rescue OptionParser::InvalidOption	
	puts $!
	print_usage
	exit
end

if ARGV.length == 0 && !$options[:best] && !$options[:top]
	print_usage
	exit
elsif ARGV.length == 1
	progname=ARGV.shift
end

if not which("rtmpdump")
    puts "rtmpdump not found"
    exit 1
end

$hc = HttpClient.new("www.arte.tv")
$hc.allowbadget = true

if progname =~ /^http:/ then
    log("Trying with URL")
    progs_data = [[progname, "", ""]]
else
    progs_data = get_progs_urls(progname)
end
puts "Dumping #{progs_data.length} program(s)"
log(progs_data, LOG_DEBUG)
progs_data.each {|p| dump_video(p[0], p[1], p[2]) }
