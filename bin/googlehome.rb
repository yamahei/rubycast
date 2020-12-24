require 'optparse'
require 'uri'

require 'mdns'
require 'castv2'

p ARGV
@name = nil
@url = nil
@text = nil
@lang = 'ja'
@usage = nil
OptionParser.new do |opt|
  opt.on('-u', '--url url', "Audio URL, set only either URL or Text") { |o| @url = o }
  opt.on('-t', '--text text', "Text to talk, set only either URL or Text") { |o| @text = o }
  opt.on('-l', '--lang lang', "Language for talk text") { |o| @lang = o }
  opt.on('-n', '--name name', "Googlehome name, if none, set all") { |o| @name = o }
  opt.on("-h", "--help", "Prints this help") { puts opt; exit }
  @usage = opt.to_s
end.parse!

if (@url && @text) || (!@url && !@text) then
  puts @usage; exit
end

if @text then
  @url = "https://translate.google.com/translate_tts?ie=UTF-8&tl=#{@lang}&client=tw-ob&q=#{URI.escape(@text)}"
end

devices = []
EventMachine.run do
  EM.add_timer(2) { EM.stop }

  mdns = MDNS.new('_googlecast._tcp.')
  mdns.on_found do |device|
    if !@name || @name == device[:name].force_encoding('UTF-8') then

      puts "FOUND: #{device[:name] }(#{device[:host]}:#{device[:port]})"
      devices.push(device).uniq!
  
    end
  end
  mdns.lookup

end

devices.uniq.each{|device|

  EventMachine.run {

    Castv2::Client.launch device[:host], device[:port] do |client|
      platform = Castv2::Platform.new(client)
      platform.connect do
        platform.launch(Castv2::DefaultMediaReceiver) do |media|
          media_data = {
              contentId: @url,
              contentType: 'audio/mp3',
              streamType: 'BUFFERED', # or LIVE
          }
          media_options = {autoplay: true}
          media.load(media_data, media_options) do |data|
            media.play { EM.stop }
          end
        end
      end
    end

  }

}
