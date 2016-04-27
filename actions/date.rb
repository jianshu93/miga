#!/usr/bin/env ruby

# @package MiGA
# @license Artistic-2.0

opts = OptionParser.new do |opt|
   opt.banner = <<BAN
Returns the current date in standard MiGA format.

Usage: #{$0} #{File.basename(__FILE__)} [options]
BAN
   opt.separator ""
   opt.on("-h", "--help", "Display this screen.") do
      puts opt
      exit
   end
   opt.separator ""
end.parse!


### MAIN
opts.parse!
puts Time.now.to_s
