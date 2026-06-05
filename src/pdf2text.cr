require "./pdf2text/version"
require "./pdf2text/bbox"
require "./pdf2text/extractor"
require "./pdf2text/html"

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
# **Scope.** Targets PDFs produced by `aloli-crystal/pdf` and
# asciidoctor-pdf : Type1 with WinAnsi encoding and TTF CIDFont
# Type0 + Identity-H + ToUnicode CMap. Content streams under
# FlateDecode are decoded; positioned text (word, bbox, font,
# size) is extracted reliably for these. HTML rendering is
# available via `Pdf2Text::Html` (the `pdf2html` binary). Not yet
# guaranteed : external/encrypted PDFs, object/xref streams
# (PDF 1.5+), exotic encodings — see the README roadmap.
module Pdf2Text
end
