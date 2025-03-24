
require 'open3'

puts ARGV.to_s
args = [
  'security',
  'find-identity',
  '-v',
  '-p',
  'codesigning'
]
puts args.to_s
stdout, status = Open3.capture2(*args)
codesigning = "\n#{stdout.strip}"
if codesigning =~ /\s+\d\s+valid\s+identit\w\w?\w?\s+found/
  codesigning = codesigning.gsub(/.*\s+1\)\s+((\w|\d)+)\s+["].*/) { "#{$1}" }
  codesigning = codesigning.split.first.strip
else
  exit
end
args = [
  'codesign',
  '--sign',
  codesigning,
  '--force',
  '--entitlements',
  File.join(Dir.pwd, 'entitlements.plist'),
  '--verbose',
  '--timestamp',
  '-o',
  'runtime',
  '--deep',
  ARGV[0]
]
puts args.to_s
system(*args)

