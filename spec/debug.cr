require "../src/pdf2text/extractor"

ext = Pdf2Text::Extractor.extract(ARGV[0])
puts "Pages found: #{ext.pages.size}"
ext.pages.each do |p|
  puts "Page #{p.number} (#{p.width.round(0)}x#{p.height.round(0)}) — #{p.words.size} words"
end
