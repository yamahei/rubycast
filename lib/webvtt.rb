class Webvtt
	attr_accessor :cues
	def initialize(filename)
		@file = File.open(filename)
		@cues = []
	end

	def timestamp_to_sec(timestamp)
		mres = timestamp.match(/([^.]+)\.(\d+)/)
		sec = mres[1].split(":").map(&:to_i).reverse
		msec = mres[2].to_f

		(sec[2] ? sec[2]*60*60 : 0) + sec[1] * 60 + sec[0] + msec/1000.0
	end

	def sec_to_timestamp(sec)
		hour = (sec/(60*60)).truncate
		min = ((sec - hour*(60*60))/60).truncate
		s = ((sec - hour*(60*60) - min*60)).truncate
		ms = (sec - sec.truncate).round(3)
		"#{"%02d" % hour}:#{"%02d" % min}:#{"%02d" % s}.#{"%03d" % ((ms*1000).round.to_i)}"
	end

	def write(io)
		io.write "WEBVTT\n\n"
		@cues.each do |cue|
			io.write "#{sec_to_timestamp(cue[:start])} --> #{sec_to_timestamp(cue[:end])}\n"
			cue[:text].each do |ctext|
				io.write ctext
			end
			io.write "\n"
		end
	end

	def parse
		@file.each_line do |line|
			case line 
			when /^WEBVTT$/
				@start = true
			when /([\d|\:|\.]+)\s\-\-\>\s([\d|\:|\.]+)/
				@cues << {start: timestamp_to_sec($1), end: timestamp_to_sec($2), text: []}
			when /^$/
				# newline
			else
				cue = @cues.last
				cue[:text]||=[]
				cue[:text] << line
			end
		end
	end
end
