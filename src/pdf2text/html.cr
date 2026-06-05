require "html"

module Pdf2Text
  # Rendu HTML d'un `Extract` — le moteur de l'utilitaire `pdftohtml`
  # de poppler-utils.
  #
  # Chaque page devient un `<div class="page">` aux dimensions du
  # MediaBox, dans lequel chaque mot est un `<span>` positionné en
  # absolu d'après sa boîte englobante. L'origine PDF (bas-gauche) est
  # convertie vers l'origine HTML (haut-gauche). Le résultat reproduit
  # fidèlement la mise en page, à la manière du mode « complexe » de
  # poppler.
  #
  # ```
  # extract = Pdf2Text::Extractor.extract("doc.pdf")
  # File.write("doc.html", Pdf2Text::Html.render(extract))
  # ```
  module Html
    # Construit le document HTML complet (autonome, un seul fichier).
    # `title` apparaît dans la balise `<title>` (défaut : la source).
    def self.render(extract : Extract, title : String? = nil) : String
      heading = title || File.basename(extract.source)
      String.build do |io|
        io << "<!DOCTYPE html>\n"
        io << "<html lang=\"fr\">\n<head>\n"
        io << "<meta charset=\"utf-8\">\n"
        io << "<title>" << HTML.escape(heading) << "</title>\n"
        io << STYLE
        io << "</head>\n<body>\n"
        extract.pages.each { |page| render_page(io, page) }
        io << "</body>\n</html>\n"
      end
    end

    # Feuille de style : pages centrées sur fond gris, mots en
    # positionnement absolu.
    STYLE = <<-CSS
      <style>
      body { margin: 0; padding: 16px 0; background: #525659; }
      .page { position: relative; margin: 0 auto 16px; background: #fff;
              box-shadow: 0 1px 4px rgba(0,0,0,.5); overflow: hidden; }
      .page span { position: absolute; white-space: pre; line-height: 1; }
      </style>\n
      CSS

    private def self.render_page(io : IO, page : Page) : Nil
      io << "<div class=\"page\" style=\"width:" << fmt(page.width)
      io << "pt;height:" << fmt(page.height) << "pt\">\n"
      page.words.each { |word| render_word(io, page, word) }
      io << "</div>\n"
    end

    private def self.render_word(io : IO, page : Page, word : Word) : Nil
      # PDF : origine bas-gauche ; HTML : origine haut-gauche.
      left = word.bbox.x_min
      top = page.height - word.bbox.y_max
      io << "<span style=\"left:" << fmt(left) << "pt;top:" << fmt(top)
      io << "pt;font-size:" << fmt(word.font_size) << "pt;font-family:"
      io << font_family(word.font_name) << "\">"
      io << HTML.escape(word.text)
      io << "</span>\n"
    end

    # Heuristique famille de police d'après le nom de la fonte PDF.
    private def self.font_family(name : String) : String
      n = name.downcase
      if n.includes?("mono") || n.includes?("courier") || n.includes?("consol")
        "monospace"
      elsif n.includes?("times") || n.includes?("serif") || n.includes?("georgia") || n.includes?("minion")
        "serif"
      else
        "sans-serif"
      end
    end

    # Formate un nombre sans zéros décimaux superflus.
    private def self.fmt(value : Float64) : String
      s = "%.2f" % value
      s = s.rstrip('0').rstrip('.') if s.includes?('.')
      s
    end
  end
end
