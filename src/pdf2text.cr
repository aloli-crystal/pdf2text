require "./pdf2text/version"
require "./pdf2text/bbox"
require "./pdf2text/extractor"

# `pdf2text` — Pure-Crystal PDF text extractor.
#
# Reads a PDF file, walks its object tree, decodes content streams
# (FlateDecode) and returns positioned text (page index, font name
# + size, bounding box in PDF points).
#
# **Quick start :**
#
# ```
# require "pdf2text"
#
# extract = Pdf2Text::Extractor.extract("doc.pdf")
# puts "Pages : #{extract.pages.size}"
# extract.pages.each do |page|
#   puts "  page #{page.number} (#{page.width} × #{page.height})"
#   page.words.each do |w|
#     puts "    \"#{w.text}\" @ (#{w.bbox.x_min}, #{w.bbox.y_min})"
#   end
# end
# ```
#
# **Scope v0.1.0 (alpha).** Targets PDFs produced by
# `aloli-crystal/pdf` : Type1 with WinAnsi encoding, TTF with
# CIDFont Type0 + Identity-H + ToUnicode CMap. Structure (page
# tree, MediaBox, font references) is reliably extracted. Text
# extraction from content streams is preliminary — many PDFs
# return 0 words for now. See the project README for the full
# roadmap (v0.2.0+ targets full WinAnsi decoding, ToUnicode CMap
# parsing, precise bbox via /Widths font metrics, AES-128/256
# decryption).
module Pdf2Text
end
