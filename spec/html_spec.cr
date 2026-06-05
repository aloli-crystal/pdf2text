require "./spec_helper"

private def sample_extract : Pdf2Text::Extract
  bbox = Pdf2Text::Bbox.new(x_min: 10.0, y_min: 800.0, x_max: 60.0, y_max: 820.0)
  word = Pdf2Text::Word.new(
    text: "A<b> & C",
    bbox: bbox,
    page: 1,
    font_size: 12.0,
    font_name: "Times-Roman",
  )
  page = Pdf2Text::Page.new(number: 1, width: 200.0, height: 842.0, words: [word])
  Pdf2Text::Extract.new(source: "doc.pdf", pages: [page])
end

describe Pdf2Text::Html do
  describe ".render" do
    it "produit un document HTML autonome" do
      html = Pdf2Text::Html.render(sample_extract)
      html.should start_with("<!DOCTYPE html>")
      html.should contain("<meta charset=\"utf-8\">")
      html.should contain("</html>")
    end

    it "échappe le texte (pas d'injection HTML)" do
      html = Pdf2Text::Html.render(sample_extract)
      html.should contain("A&lt;b&gt; &amp; C")
      html.should_not contain("A<b> & C")
    end

    it "dimensionne la page au MediaBox" do
      html = Pdf2Text::Html.render(sample_extract)
      html.should contain("width:200pt;height:842pt")
    end

    it "convertit l'origine PDF (bas-gauche) vers HTML (haut-gauche)" do
      # top = hauteur page (842) − y_max (820) = 22
      html = Pdf2Text::Html.render(sample_extract)
      html.should contain("left:10pt;top:22pt")
      html.should contain("font-size:12pt")
    end

    it "applique l'heuristique de famille de police" do
      html = Pdf2Text::Html.render(sample_extract)
      # "Times-Roman" → serif
      html.should contain("font-family:serif")
    end

    it "utilise la source comme titre par défaut, surclassée par l'argument" do
      Pdf2Text::Html.render(sample_extract).should contain("<title>doc.pdf</title>")
      Pdf2Text::Html.render(sample_extract, "Mon titre").should contain("<title>Mon titre</title>")
    end
  end
end
