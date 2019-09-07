require 'optparse'

require 'mdns'
require 'castv2'
require 'streaming_server'

local_priv_addr = Socket.ip_address_list.detect { |intf| intf.ipv4_private? }

@host = local_priv_addr ? local_priv_addr.ip_address : nil
@port = 8015
@encoder = "h264"
@audio_lang = "eng"
@subtitle_lang = "eng"
@audio_map = nil
@subtitle_map = nil
@command = nil
@position = 0.0
@verbose = nil
@root = "/tmp"

OptionParser.new do |opt|
  opt.on('-c', '--command command', "Execute command (load, play, pause, stop, kill)") { |o| @command = o }
  opt.on('--host host', "HTTP server bind address") { |o| @host = o }
  opt.on('--port port', "HTTP server bind port") { |o| @port = o.to_i }
  opt.on('--httpd', "HTTP server mode") { |o| @httpd = true }
  opt.on('--daemon', "Run HTTP server as daemon") { |o| @daemonize = true }
  opt.on('--root directory', "Root directory for file browser") { |o| @root = o }
  opt.on('-f', '--file filename', "Video filename") { |o| @filename = o }
  opt.on('--info', "Show video file streams info") { |o| @info = true }
  opt.on("--detect", "Detect chromecast") { |o| @detect = true }
  opt.on('--url url', "Video URL") { |o| @url = o }
  opt.on('--position position', "Position in second to start the video") { |o| @position = o.to_f }
  opt.on('--encoder encoder', "ffmpeg video encoder") { |o| @encoder = o }
  opt.on('--audio-lang lang', "Audio language stream") { |o| @audio_lang = o }
  opt.on('--audio-map stream') { |o| @audio_map = o.to_i }
  opt.on('--subtitle-lang lang', "Subtitle language stream") { |o| @subtitle_lang = o }
  opt.on('--subtitle-map stream') { |o| @subtitle_map = o.to_i }
  opt.on('--transcode', "Transcode video using ffmpeg") { |o| @transcode = true }
  opt.on('-v', "--verbose", "Verbose") { |o| @verbose = true }
  opt.on("-h", "--help", "Prints this help") do
    puts opt
    exit
  end
  if ARGV.length == 0
    puts opt
    exit
  end
end.parse!

if @detect
  EventMachine.run do
    @volume = nil

    mdns = MDNS.new('_googlecast._tcp.')
    mdns.on_found do |device|
      puts "FOUND #{device}"
    end
    mdns.lookup
    EM.add_timer(10) do
      EM.stop
    end
  end
end

if @httpd
  Process.daemon if @daemonize
  EventMachine.run do
    mdns = MDNS.new('_googlecast._tcp.')
    mdns.on_found do |device|
      puts "FOUND #{device}"
      mdns.stop
      EM.start_server @host, @port, StreamingServer do |conn|
        conn.host = @host
        conn.port = @port
        conn.root = @root
        conn.encoder = @encoder

        conn.chromecast_host = device[:host]
        conn.chromecast_port = device[:port]
      end
    end
    mdns.lookup
  end
  exit
end

if @filename and @command == "load"
  @video = VideoFile.new(@filename, @encoder)
  @video.map_streams(@audio_lang, @subtitle_lang)

  if @info
    puts "#{File.basename(@filename)} streams:"
    @video.print_streams
  else
    sub_filename = "#{File.dirname(@filename)}/#{File.basename(@filename, File.extname(@filename))}.#{@subtitle_lang}.vtt"
    unless File.exist?(sub_filename)
      sub_cmd = @video.sub_cmd(@position, sub_filename)
      puts "Preparing sub: #{sub_cmd}" if @verbose
      system(sub_cmd)
    end
  end
end

if @command and not @info
  EventMachine.run do
    @volume = nil

    EM.add_timer(1) do
      mdns = MDNS.new('_googlecast._tcp.')
      mdns.on_found do |device|
        mdns.stop
        Castv2::Client.launch device[:host], device[:port] do |client|
          platform = Castv2::Platform.new(client)

          platform.connect do
            platform.restore_or_launch(Castv2::DefaultMediaReceiver) do |media|
              case @command
              when "kill"
                platform.stop do |data|
                  EM.stop
                end
              when "stop"
                media.stop do |data|
                  EM.stop
                end
              when "pause"
                media.pause do |data|
                  EM.stop
                end
              when "play"
                media.play do |data|
                  EM.stop
                end
              when "load"
                url = @url
                title = ""
                if @filename
                  url = "http://#{@host}:#{@port}/direct?u=#{@filename}"
                  if @transcode
                    url = "http://#{@host}:#{@port}/transcode?u=#{@filename}&encoder=#{@encoder}&lang=#{@audio_lang}&position=#{@position}"
                  end
                  title = File.basename(@filename)
                end

                media_data = {
                    contentId: url,

                    contentType: 'video/mp4',
                    streamType: 'BUFFERED', # or LIVE

                    metadata: {
                        type: 0,
                        metadataType: 0,
                        title: title
                    }
                }

                if @video
                  media_data[:duration] = @video.duration
                end

                tracks = []
                if @video and @video.map_subtitle > -1
                  tracks = [{
                                trackId: 1,
                                type: 'TEXT',
                                trackContentId: "http://#{@host}:#{@port}/subtitle?u=#{sub_filename}&position=#{@position}",
                                trackContentType: 'text/vtt',
                                name: @subtitle_lang,
                                language: @subtitle_lang,
                                subtype: 'SUBTITLES'
                            }]
                end

                platform.get_volume do |volume|
                  @volume = volume
                end

                media_options = {autoplay: true}
                if tracks.length > 0
                  media_data[:tracks] = tracks
                  media_options[:activeTrackIds] = [1]
                end
                media.load(media_data, media_options) do |data|
                  EM.stop
                end
              else
                puts "Error: Unknown command #{@command}"
                EM.stop
              end
            end
          end
        end
      end
      mdns.lookup
    end
  end
end
