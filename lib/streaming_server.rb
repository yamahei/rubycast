require 'cgi'

require 'eventmachine'
require 'evma_httpserver'
require 'erector'

require 'castv2'
require 'video_file'
require 'webvtt'

class StreamingServer < EM::Connection
  include EM::HttpServer

  attr_accessor :params, :headers,
                :host, :port,
                :root, :encoder,
                :chromecast_host, :chromecast_port

  def initialize
    @disconnect_channel = EM::Channel.new
  end

  def post_init
    super
    no_environment_strings
  end

  def unbind
    @disconnect_channel.push Time.now
  end

  def parse_params
    @params = {}
    if @http_query_string
      @http_query_string.split("&").each do |arg|
        @params[arg.split("=").first] = arg.split("=").last
      end
    end
  end

  def parse_headers
    @headers = {}
    @http_headers.split("\x00").each do |arg|
      @headers[arg.split(":").first] = arg.split(":")[1..-1].join(":").strip
    end
  end

  def cast_media &block
    Castv2::Client.launch self.chromecast_host, self.chromecast_port do |client|
      platform = Castv2::Platform.new(client)
      platform.connect do
        platform.restore_or_launch(Castv2::DefaultMediaReceiver) do |media|
          block.call client, platform, media
        end
      end
    end
  end

  def process_http_request
    response = nil
    self.parse_headers
    self.parse_params
    case @http_request_uri
    when "/"
      response = EM::DelegatedHttpResponse.new(self)
      response.send_redirect "/explore"
    when "/streaming.js"
      js_filename = File.join(File.dirname(__FILE__), "../lib/streaming.js")
      response = EM::DelegatedHttpResponse.new(self)
      response.status = 200
      response.content_type 'text/javascript'

      js_code = File.read(js_filename)
      response.content = js_code
      response.send_response

    when "/hello"
      response = EM::DelegatedHttpResponse.new(self)
      response.status = 200
      response.content_type 'text/html'
      response.content = Erector.inline do
        html do
          head do
            title "Hello"
          end
          body do
            p "Hello #{self.host}:#{self.port}"
          end
        end
      end.to_html
      response.send_response

    when "/play"
      response = EM::DelegatedHttpResponse.new(self)
      self.cast_media do |client, platform, media|
        media.play do
          platform.disconnect
          client.close_connection true
        end
      end
      response.status = 200
      response.content_type 'text/html'
      response.content = "play"
      response.send_response
    when "/stop"
      response = EM::DelegatedHttpResponse.new(self)
      self.cast_media do |client, platform, media|
        media.stop do
          platform.disconnect
          client.close_connection true
        end
      end
      response.status = 200
      response.content_type 'text/html'
      response.content = "stop"
      response.send_response

    when "/pause"
      response = EM::DelegatedHttpResponse.new(self)
      self.cast_media do |client, platform, media|
        media.pause do
          platform.disconnect
          client.close_connection true
        end
      end
      response.status = 200
      response.content_type 'text/html'
      response.content = "pause"
      response.send_response
    when "/seek"
      position = @params["position"].to_i
      response = EM::DelegatedHttpResponse.new(self)
      self.cast_media do |client, platform, media|
        media.seek(position) do
          platform.disconnect
          client.close_connection true
        end
      end
      response.status = 200
      response.content_type 'text/html'
      response.content = "seek"
      response.send_response
    when "/load"
      file = @params["u"]
      file = CGI::unescape(file) if file
      response = EM::DelegatedHttpResponse.new(self)

      video = VideoFile.new(file)

      position = params["position"] || 0
      subtitle = params["subtitle"]
      sub_filename = nil
      if subtitle
        puts "SUBTITLE"
        video.map_subtitle = subtitle.to_i
        sub_filename = "#{File.dirname(file)}/#{File.basename(file, File.extname(file))}.#{subtitle}.vtt"
        unless File.exist?(sub_filename)
          sub_cmd = video.sub_cmd(0, sub_filename)
          puts "Preparing sub: #{sub_cmd}"
          system(sub_cmd)
        end
      end

      self.cast_media do |client, platform, media|
        url = "http://#{@host}:#{@port}/direct?u=#{file}"
        if params["transcode"] == "true"
          url = "http://#{@host}:#{@port}/transcode?u=#{file}&encoder=#{self.encoder}&stream=#{params["stream"]}&position=#{position}"
        end

        media_data = {
            contentId: url,

            contentType: 'video/mp4',
            streamType: 'BUFFERED', # or LIVE

            metadata: {
                type: 0,
                metadataType: 0,
                title: File.basename(file)
            }
        }
        tracks = []
        if subtitle
          tracks = [{
                        trackId: 1,
                        type: 'TEXT',
                        trackContentId: "http://#{self.host}:#{self.port}/subtitle?u=#{sub_filename}&position=#{position}",
                        trackContentType: 'text/vtt',
                        name: "fr",
                        language: "fr",
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
        media.load(media_data, media_options) do
          platform.disconnect
          client.close_connection true
        end
      end

      response.status = 200
      response.content_type 'text/html'
      response.content = "play"
      response.send_response
    when "/player"
      file = @params["u"]
      file = CGI::unescape(file) if file
      if File.exist?(file)
        video = VideoFile.new(file)

        response = EM::DelegatedHttpResponse.new(self)
        response.status = 200
        response.content_type 'text/html'
        self.cast_media do |client, platform, media|
          media.get_status do |status|
            current_time = 0
            loaded = false
            paused = false
            playing = false
            if status.first
              puts status
              current_time = status.first.currentTime
              loaded = true
              case status.first.playerState
              when "PAUSED"
                paused = true
              when "PLAYING"
                playing = true
              end
            end
            response.content = Erector.inline do
              html do
                head do
                  title "Player"

                  meta charset: "UTF-8"

                  link rel: "stylesheet", href: "//cdnjs.cloudflare.com/ajax/libs/normalize/5.0.0/normalize.css"
                  link rel: "stylesheet", href: "//cdnjs.cloudflare.com/ajax/libs/milligram/1.3.0/milligram.css"

                  script src: "https://code.jquery.com/jquery.min.js"
                  script src: "/streaming.js"
                end

                body do
                  div class: "container" do
                    h2 "Playing #{File.basename(file)}"
                    form id: "player" do
                      div class: "row" do
                        div class: "column column-90" do
                          input type: "range", id: "position", name: "position", min: 0, max: video.duration.round, value: current_time.round, style: "width: 100%;"
                        end
                        div class: "column column-10" do
                          span current_time.round, id: "current_time"
                          span "/"
                          span video.duration.round
                        end
                      end

                      div class: "row" do
                        div class: "column column-10" do
                          a "Play", id: "play", href: "#"
                        end
                        div class: "column column-10" do
                          a "Pause", id: "pause", href: "#"
                        end
                        div class: "column column-10" do
                          a "Stop", id: "stop", href: "#"
                        end
                      end

                      div class: "row" do
                        input type: "hidden", id: "u", name: "u", value: file
                        input type: "hidden", id: "loaded", name: "loaded", value: loaded
                        input type: "hidden", id: "paused", name: "paused", value: paused
                        input type: "hidden", id: "playing", name: "playing", value: playing
                      end

                      div class: "row" do
                        div class: "column" do
                          span "Audio"
                          select id: "audio_stream", name: "audio_stream" do
                            video.audio_streams.each do |stream|
                              if stream["tags"]
                                option "#{stream["tags"]["title"]} (#{stream["tags"]["language"]})", value: stream["index"]
                              else
                                option "#{stream["index"]}", value: stream["index"]
                              end
                            end
                          end
                        end

                        div class: "column" do
                          span "Subtitle"
                          select id: "subtitle_stream", name: "subtitle_stream" do
                            video.subtitle_streams.each do |stream|
                              if stream["tags"]
                                option "#{stream["tags"]["title"]} (#{stream["tags"]["language"]})", value: stream["index"]
                              else
                                option "#{stream["index"]}", value: stream["index"]
                              end
                            end
                          end
                        end
                        div class: "column" do
                          input type: "checkbox", id: "transcode", name: "transcode", checked: self.params["transcode"] ? true : false
                          span "Transcode"
                        end
                      end
                    end
                    div do
                      a "Return to explore", href: "/explore?d=#{File.dirname(file).sub(self.root, "")}"
                    end
                  end
                end
              end
            end.to_html
            response.send_response
            platform.disconnect
            client.close_connection true
          end
        end
      else
        response = EM::DelegatedHttpResponse.new(self)
        response.status = 404
        response.content_type 'text/html'
        response.content = 'File not found'
        response.send_response
      end
    when "/explore"
      subdir = @params["d"] || ""
      subdir = CGI::unescape(subdir) if subdir
      dir = "#{self.root}/#{subdir}"
      files = Dir.glob("#{dir}/*")
      files.select! do |file|
        File.directory?(file) or [".mp4", ".mkv", ".avi"].include?(File.extname(file))
      end
      files.sort!
      response = EM::DelegatedHttpResponse.new(self)
      response.status = 200
      response.content_type 'text/html'
      response.content = Erector.inline do
        html do
          head do
            title "Explore"

            meta charset: "UTF-8"

            link rel: "stylesheet", href: "//cdnjs.cloudflare.com/ajax/libs/normalize/5.0.0/normalize.css"
            link rel: "stylesheet", href: "//cdnjs.cloudflare.com/ajax/libs/milligram/1.3.0/milligram.css"

            script src: "https://code.jquery.com/jquery.min.js"
            script src: "/streaming.js"
          end
          body do

            div class: "container" do
              h2 "Explore"
              table do
                pardir = File.dirname(subdir)
                if pardir != "."
                  tr do
                    td do
                      a pardir, href: "/explore?d=#{pardir}"
                    end
                  end
                end
                files.each do |file|
                  tr do
                    td do
                      if File.directory?(file)
                        strong do
                          a File.basename(file), href: "/explore?d=#{subdir}/#{File.basename(file)}"
                        end
                      else
                        a File.basename(file), href: "/player?u=#{file}"
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end.to_html
      response.send_response

    when "/subtitle"
      file = @params["u"]
      file = CGI::unescape(file) if file
      if File.exist?(file)

        position = (@params["position"] ||= 0).to_f

        vtt = Webvtt.new(file)
        vtt.parse

        retimed_cues = []
        vtt.cues.each do |cue|
          if cue[:start] > position
            cue[:start] -= position
            cue[:end] -= position
            retimed_cues << cue
          end
        end
        vtt.cues = retimed_cues

        vtt_str = StringIO.new
        vtt.write(vtt_str)
        #puts "StreamingServer: #{Time.now} start video transcoding sub #{file}"

        @disconnect_channel.subscribe do |time|
          #puts "StreamingServer: #{Time.now} end video transcoding sub #{file}"
        end

        response = EM::DelegatedHttpResponse.new(self)
        response.status = 200
        response.content_type 'text/vtt'
        response.headers['Access-Control-Allow-Origin'] = @headers["Origin"]
        response.content = vtt_str.string
        response.send_response

      else
        response = EM::DelegatedHttpResponse.new(self)
        response.status = 404
        response.content_type 'text/html'
        response.content = 'File not found'
        response.send_response
      end
    when "/direct"
      file = @params["u"]
      file = CGI::unescape(file) if file
      if File.exist?(file)
        video = VideoFile.new(file)
        fio = File.open(file)
        response = EM::DelegatedHttpResponse.new(self)
        response.status = 206
        response.content_type video.mime

        filesize = File.size(file)
        range_len = 1024 * 1024
        range = 0

        if @headers["Range"]
          range = @headers["Range"].gsub(/bytes\=(\d+)\-.*/, '\1').to_i
        end

        fio.seek(range)
        data = fio.read(range_len)
        response.content = data

        response.headers['Cache-Control'] = "no-cache"
        response.headers['Accept-Ranges'] = "bytes"
        endrange = range + range_len
        response.headers['Content-Range'] = "bytes #{range}-#{endrange < filesize ? endrange - 1 : filesize - 1}/#{filesize}"

        response.send_response
      else
        response = EM::DelegatedHttpResponse.new(self)
        response.status = 404
        response.content_type 'text/html'
        response.content = 'File not found'
        response.send_response
      end
    when "/transcode"
      file = @params["u"]
      file = CGI::unescape(file) if file
      if File.exist?(file)
        encoder = @params["encoder"] ||= "h264"
        audio_lang = @params["lang"] ||= "eng"
        audio_stream = @params["stream"]
        position = (@params["position"] ||= 0).to_f

        video = VideoFile.new(file, encoder)
        video.map_streams(audio_lang)
        if audio_stream
          video.map_audio = audio_stream.to_i
        end
        video.start(position)

        #puts "StreamingServer: #{Time.now} start video transcoding #{file}"

        @disconnect_channel.subscribe do |time|
          #puts "StreamingServer: #{Time.now} end video transcoding #{file}"
          video.stop
        end

        response = EM::DelegatedHttpResponse.new(self)
        response.status = 200
        response.content_type 'video/mp4'
        response.headers['Access-Control-Allow-Origin'] = @headers["Origin"]
        EM.add_periodic_timer(0.01) do
          if video.transcoding
            if get_outbound_data_size < 1024 * 1024 * 4
              response.chunk video.stream.read(1024 * 1024)
              response.send_chunks
            end
          else
            :stop
          end
        end
      else
        response = EM::DelegatedHttpResponse.new(self)
        response.status = 404
        response.content_type 'text/html'
        response.content = 'File not found'
        response.send_response
      end
    else
      response = EM::DelegatedHttpResponse.new(self)
      response.status = 404
      response.content_type 'text/html'
      response.content = 'Not found'
      response.send_response
    end
    puts "StreamingServer: #{Time.now} #{@http_request_method} #{response.status} #{@http_request_uri}#{@http_query_string ? "?" : ""}#{@http_query_string}" if response
  end
end
