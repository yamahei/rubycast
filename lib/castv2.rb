require 'ostruct'
require 'forwardable'
require 'eventmachine'
require 'cast_channel.pb'

# Chromecast CASTV2 protocol ruby implementation

module Castv2

  DEBUG = false

  class Message
    attr_accessor :source_id, :destination_id, :namespace, :data_hash, :data
    def initialize(source_id, destination_id, namespace, data)
      @source_id = source_id
      @destination_id = destination_id
      @namespace = namespace
      @data = data
    end

    def data
      Message.to_ostruct(@data)
    end

    def broadcast?
      @destination_id == "*"
    end

    def destinated_to?(id)
      @destination_id == id or self.broadcast?
    end

    def to_packet
      packet = {
        protocol_version: 0, # CASTV2_1_0
        source_id: @source_id,
        destination_id: @destination_id,
        namespace: @namespace
      }

      packet[:payload_type] = 0 # STRING
      packet[:payload_utf8] = @data.to_json

      request = Extensions::Api::Cast_channel::CastMessage.new(packet)
      buf = request.encode
      [buf.length].pack("L>")+buf
    end

    def self.from_packet(raw_data)
      message = Extensions::Api::Cast_channel::CastMessage.decode(raw_data).try(:to_hash)
      if message
        Message.new(message[:source_id], message[:destination_id], message[:namespace], JSON.parse(message[:payload_utf8]))
      else
        nil
      end
    end

    def self.to_ostruct(hash)
      OpenStruct.new(hash.each_with_object({}) do |(key, val), memo|
                       memo[key] = (case val
                       when Hash
                         to_ostruct(val)
                       when Array
                         val.map do |aval|
                           if aval.is_a?(Hash)
                             to_ostruct(aval)
                           else
                             aval
                           end
                         end
                       else
                         val
                       end)
      end)
    end

    def inspect
      {source_id: @source_id, destination_id: @destination_id, namespace: @namespace, data: @data}
    end

    def to_s
      self.inspect.to_s
    end
  end

  class Client < EventMachine::Connection
    def initialize(*args)
      super
      @receive_channels = {}
    end

    def receive_data(data)
      len = data[0..3].unpack("L>").first
      packet = data[4..(len+4)]

      if data.length != len+4
        raise "TODO multiple packets #{data.length} != #{len+4}"
      end

      message = Message.from_packet(packet)

      puts "DEBUG: receive #{message}" if DEBUG

      receive_channel = @receive_channels[message.namespace]
      if receive_channel
        receive_channel.push(message)
      end
    end

    def unbind
      puts "DEBUG: connection totally closed" if DEBUG
      @on_disconnect.call if @on_disconnect
    end

    def connection_completed
      start_tls
    end

    def ssl_handshake_completed
      @on_connect.call if @on_connect
    end

    # shortcut
    def self.launch(host, port = 8009, &block)
      client = EventMachine.connect host, port, self
      client.on_disconnect do
#        puts "DEBUG: reconnect" if DEBUG
#        client.on_connect do
#        end
#        client.reconnect host, port
      end
      if block
        block.call client
      end
      client
    end

    def send_message(message)
      puts "DEBUG: send #{message}" if DEBUG
      send_data(message.to_packet)
    end

    def on_connect &block
      @on_connect = block
    end

    def on_disconnect &block
      @on_disconnect = block
    end

    def on_receive(namespace, &block)
      @receive_channels[namespace]||=EventMachine::Channel.new
      @receive_channels[namespace].subscribe block
    end
  end

  class Controller
    def initialize(client, source_id, destination_id, namespace)
      @client = client
      @source_id = source_id
      @destination_id = destination_id
      @namespace = namespace
    end

    def send_data(data)
      message = Message.new(@source_id, @destination_id, @namespace, data)
      @client.send_message(message)
    end

    def on_receive &block
      @client.on_receive(@namespace) do |message|
        if message.destinated_to?(@source_id)
          block.call message
        end
      end
    end
  end

  class HeartbeatController < Controller
    def initialize(client, source_id, destination_id)
      super(client, source_id, destination_id, 'urn:x-cast:com.google.cast.tp.heartbeat')
    end

    def ping
      self.send_data({type: 'PING'})
    end
  end

  class ConnectionController < Controller
    def initialize(client, source_id, destination_id)
      super(client, source_id, destination_id, 'urn:x-cast:com.google.cast.tp.connection')
    end

    def connect
      self.send_data({ type: 'CONNECT' })
    end

    def disconnect
      self.send_data({ type: 'CLOSE' })
    end
  end

  class RequestResponseController < Controller
    def initialize(client, source_id, destination_id, namespace)
      super(client, source_id, destination_id, namespace)

      @last_request_id = 0
      @callback = nil
    end

    def request(data, &block)
      @last_request_id += 1
      request_id = @last_request_id
      data[:requestId] = request_id
      self.send_data(data)
      if block
        self.on_receive do |message|
          if message.data.requestId == request_id
            block.call message.data
          end
        end
      end
    end
  end

  class ReceiverController < RequestResponseController
    def initialize(client, source_id, destination_id)
      super(client, source_id, destination_id, 'urn:x-cast:com.google.cast.receiver')
    end

    def get_status &block
      self.request({type: "GET_STATUS"}) do |data|
        block.call data.status
      end
    end

    def get_sessions &block
      self.get_status do |status|
        block.call status.applications
      end
    end

    def get_app_availability app_id, &block
      self.request({type: "GET_APP_AVAILABILITY", appId: [app_id]}) do |data|
        block.call data.availability
      end
    end

    def app_session(app_id, sessions)
      sessions.select{|st| st.appId == app_id}.first
    end

    def launch(app_id, &block)
      self.request({type: "LAUNCH", appId: app_id}) do |data|
        if data.status.applications
          session = self.app_session(app_id, data.status.applications)
          if session
            block.call session
          end
        end
      end
    end

    def stop(session_id, &block)
      self.request({type: "STOP", sessionId: session_id}, &block)
    end

    def set_volume(volume, &block)
      self.request({type: "SET_VOLUME", volume: {level: volume}}, &block)
    end

    def get_volume &block
      self.get_status do |status|
        block.call status.volume.level
      end
    end
  end

  class MediaController < RequestResponseController
    def initialize(client, source_id, destination_id)
      super(client, source_id, destination_id, 'urn:x-cast:com.google.cast.media')
      @current_session = nil

      self.on_receive do |message|
        if message.broadcast? and message.data.type == "MEDIA_STATUS"
          @current_session = message.data.status.first
        end
      end
    end

    def get_status &block
      self.request({type: "GET_STATUS"}) do |data|
        @current_session = data.status[0]
        if block
          block.call data.status
        end
      end
    end

    def load(media, options = {}, &block)
      req = {type: 'LOAD',
             autoplay: options[:autoplay]||false,
             currentTime: options[:currentTime]||0,
             activeTrackIds: options[:activeTrackIds]||[],
             repeatMode: options[:repeatMode]||"REPEAT_OFF"
             }

      req[:media] = media
      self.request(req) do |data|
        status = data.status
        if status and status.first and status.first.media
          block.call data
        end
      end
    end

    def session_request(data, &block)
      if @current_session
        data[:mediaSessionId] = @current_session.mediaSessionId
        self.request(data, &block)
      else
        # get session if we don't have one
        self.get_status do |status|
          if @current_session
            data[:mediaSessionId] = @current_session.mediaSessionId
            self.request(data, &block)
          end
        end
      end
    end

    def play &block
      self.session_request({type: "PLAY"}, &block)
    end

    def pause &block
      self.session_request({type: "PAUSE"}, &block)
    end

    def stop &block
      self.session_request({type: "STOP"}, &block)
    end

    def edit_tracks_info track_ids, &block
      self.session_request({type: "EDIT_TRACKS_INFO", activeTrackIds: track_ids}, &block)
    end

    def seek(current_time, &block)
      data = {
        type: 'SEEK',
        currentTime: current_time
      }
      self.session_request(data, &block)
    end
  end

  class Sender
    attr_accessor :source_id, :destination_id
    def initialize(client, source_id, destination_id)
      @client = client
      @source_id = source_id
      @destination_id = destination_id
    end

    def create_controller(klass)
      klass.new(@client, @source_id, @destination_id)
    end
  end

  class Application < Sender
    attr_accessor :connection
    def self.app_id
      nil
    end

    def initialize(client, session)
      super(client, "client-#{rand(10e5)}", session.transportId)
      @session = session
    end

    def connect
      @connection = self.create_controller(ConnectionController)
      @connection.connect
    end
  end

  class DefaultMediaReceiver < Application
    extend Forwardable
    attr_accessor :media
    def_delegators :@media, :get_status, :load, :play, :seek, :pause, :stop

    def self.app_id
      'CC1AD845'
    end

    def initialize(client, session)
      super(client, session)
      @media = self.create_controller(MediaController)
    end
  end

  class Platform < Sender
    attr_accessor :application
    extend Forwardable

    def_delegators :@receiver, :get_status, :get_sessions, :app_session, :get_app_availability, :set_volume, :get_volume

    def initialize(client)
      super(client, 'sender-0', 'receiver-0')

      @connection = self.create_controller(ConnectionController)
      @heartbeat = self.create_controller(HeartbeatController)
      @receiver = self.create_controller(ReceiverController)

      @application = nil
    end

    def stop &block
      @receiver.stop(@session.sessionId)
      @connection.disconnect
      if block
       EM.add_timer(1) do
          block.call
        end
      end
    end

    def disconnect &block
      @connection.disconnect
      @hearbeat_timer.cancel if @hearbeat_timer
    end

    def connect &block
      @client.on_connect do
        @connection.connect

        @heartbeat.on_receive do |message|
          if message.data.type == "PONG"
            #puts "PONG"
          end
        end

        @hearbeat_timer = EM.add_periodic_timer(5) do
          @heartbeat.ping
        end

        block.call
      end
    end

    def join(session, app, &block)
      @session = session
      @application = app.new(@client, session)
      @application.connect
      block.call @application
    end

    def restore(app, &block)
      self.get_sessions do |sessions|
        session = self.app_session(app.app_id, sessions)
        if session
          self.join(session, app, &block)
        end
      end
    end

    def launch(app, &block)
      @receiver.launch(app.app_id) do |session|
        self.join(session, app, &block)
      end
    end

    def restore_or_launch(app, &block)
      self.get_sessions do |sessions|
        session = self.app_session(app.app_id, sessions)
        if session
          self.join(session, app, &block)
        else
          self.launch(app, &block)
        end
      end
    end
  end
end
