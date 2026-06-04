require "../src/pdf2text/extractor"

extract = Pdf2Text::Extractor.extract(ARGV[0])
puts "Pages: #{extract.pages.size}"
puts "Total words: #{extract.total_words}"
extract.pages.first(2).each do |page|
  puts "--- Page #{page.number} ---"
  page.words.first(8).each do |w|
    printf("  %-30s @ (%.1f, %.1f) size=%.1f\n", w.text, w.bbox.x_min, w.bbox.y_min, w.font_size)
  end
end
