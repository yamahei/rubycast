
require 'json'
require 'open3'

require 'sys/proctable'

class VideoFile
  attr_accessor :file, :transcoding, :json, :duration,
    :mime, :video_stream, :audio_stream,
    :map_video, :map_audio, :map_subtitle
  def initialize(file, encoder = "h264")
    @file = file
    @encoder = encoder

    @json = self.probe

    if @json
      @duration = @json["format"]["duration"].to_f

      case @json["format"]["format_name"]
      when /matroska/
        @mime = "video/x-matroska"
      when /mp4/
        @mime = "video/mp4"
      end
    end

    @map_video = -1
    @map_audio = -1
    @map_subtitle = -1
  end

  def video_streams
    @json["streams"].select do |stream|
      stream["codec_type"]=="video"
    end
  end

  def audio_streams
    @json["streams"].select do |stream|
      stream["codec_type"]=="audio"
    end
  end

  def subtitle_streams
    @json["streams"].select do |stream|
      stream["codec_type"]=="subtitle"
    end
  end

  def map_streams(audio_lang = "eng", subtitle_lang = "eng")
    json["streams"].each do |stream|
      case stream["codec_type"]
      when "video"
        if @map_video == -1
          @map_video = stream["index"].to_i
          @video_stream = stream
        end
      when "audio"
        if stream["tags"] and stream["tags"]["language"] == audio_lang and @map_audio == -1
          @map_audio = stream["index"].to_i
          @audio_stream = stream
        end
        if audio_lang == nil and @map_audio == -1
          @map_audio = stream["index"].to_i
          @audio_stream = stream
        end
      when "subtitle"
        if ["subrip","ass"].include?(stream["codec_name"]) and stream["tags"] and stream["tags"]["language"] == subtitle_lang and @map_subtitle == -1
          @map_subtitle = stream["index"].to_i
        end
        if subtitle_lang == nil and @map_audio == -1
          @map_subtitle = stream["index"].to_i
        end
      end
    end

    json["streams"].each do |stream|
      case stream["codec_type"]
      when "video"
        if @map_video == -1
          @map_video = stream["index"].to_i
          @video_stream = stream
        end
      when "audio"
        if @map_audio == -1
          @map_audio = stream["index"].to_i
          @audio_stream = stream
        end
      when "subtitle"
        if ["subrip","ass"].include?(stream["codec_name"]) and @map_subtitle == -1
          @map_subtitle = stream["index"].to_i
        end
      end
    end
  end

  def print_streams
    puts "Video format: #{json["format"]["format_name"]}"
    puts "Video streams:"
    json["streams"].each do |stream|
      puts " index:#{stream["index"]} type:#{stream["codec_type"]} codec:#{stream["codec_name"]} lang:#{stream["tags"]["language"]} (#{stream["tags"]["title"]})"
    end
  end

  def probe
    probe_cmd = "ffprobe -print_format json -show_format -show_streams -show_error \"#{@file}\" 2> /dev/null"
    r=`#{probe_cmd}`
    JSON.parse(r)
  end


  def sub_cmd(position=0, out="pipe:1")
    "ffmpeg -hide_banner -y -i \"#{@file}\" -ss #{position} -loglevel panic -map 0:#{@map_subtitle} -scodec webvtt -f webvtt \"#{out}\" 2> /dev/null"
  end

  def start_sub
    unless @transcoding
      ffmpeg_cmd = self.sub_cmd
      puts "VideoFile: #{ffmpeg_cmd}"
      stdin, stdout, wait_thr = Open3.popen2(ffmpeg_cmd)
      @thr = wait_thr
      @transcoding = true
      @stream = stdout
    end
  end

  def transcode_cmd(position=0, out = "pipe:1")
    vid_encoder = @encoder
    aud_encoder = "aac"
    if ["aac","mp3"].include?(@audio_stream["codec_name"])
      aud_encoder = "copy"
    end
    if ["h264"].include?(@video_stream["codec_name"])
      vid_encoder = "copy"
    end

    unless vid_encoder=="copy"
      vid_scale = "640:-2"
      #vid_scale = "-1:720"
      scale="-vf scale=#{vid_scale}"
    end

    "/usr/bin/ffmpeg -loglevel error -stats -hide_banner -y -ss #{position} -i \"#{@file}\" -vcodec #{vid_encoder} -f mp4 -movflags frag_keyframe+empty_moov+faststart -strict experimental -acodec #{aud_encoder} -ac 2 -vb 2M -pix_fmt nv21 #{scale} -sws_flags fast_bilinear -map 0:#{@map_video} -map 0:#{@map_audio} #{out}"
  end

  def start(position=0, out = "pipe:1")
    unless @transcoding
      ffmpeg_cmd = self.transcode_cmd(position, out)
      puts "VideoFile: #{ffmpeg_cmd}"
      stdin, stdout, wait_thr = Open3.popen2(ffmpeg_cmd)
      @thr = wait_thr
      puts "ffmpeg START #{@thr.pid}/#{Process.getpgid(@thr.pid)}"
      @transcoding = true
      @stream = stdout
    end
  end

  def stop
    if @thr
      begin
        puts "ffmpeg KILL #{@thr.pid}"
        # needed to kill all ffmpeg subprocesses
        to_kill = [@thr.pid]
        Sys::ProcTable.ps do |proc|
		    to_kill << proc.pid if to_kill.include?(proc.ppid)
  		end

        Process.kill("KILL", *to_kill)
      rescue => e
        puts "VideoFile: cannot term process : #{e}"
      end
      @transcoding = false
    end
  end

  def stream
    @stream
  end
end
