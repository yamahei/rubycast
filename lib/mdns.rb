require 'dnssd'
require 'eventmachine'

class MDNS
  def initialize(name)
    @name = name
    @channel = EventMachine::Channel.new
  end

  def on_found &callback
    @channel.subscribe callback
  end

  def stop
    @service.stop if @service
    @channel = EventMachine::Channel.new
  end

  def lookup
    find_devices!
  end

  private

  def find_devices!
    @service = DNSSD.browse(@name) do |node|
      DNSSD.resolve(node) do |resolved|
        host = Socket.getaddrinfo(resolved.target, nil, Socket::AF_INET)[0][2]
        device = {name: resolved.text_record["fn"], host: host, port: resolved.port}
        @channel.push device
        next unless resolved.flags.more_coming?
      end
    end
  end
end
