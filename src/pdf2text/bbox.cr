module Pdf2Text
  # Bounding box d'un élément de page PDF (mot, ligne, page),
  # avec coordonnées en points PDF (1 pt = 1/72 pouce).
  #
  # Convention : `y_min` est le bord BAS (PDF natif), `y_max` le
  # bord HAUT. L'origine PDF est en BAS À GAUCHE de la page.
  # `width = x_max - x_min`, `height = y_max - y_min`.
  record Bbox,
    x_min : Float64,
    y_min : Float64,
    x_max : Float64,
    y_max : Float64 do
    def width : Float64
      x_max - x_min
    end

    def height : Float64
      y_max - y_min
    end

    # Distance horizontale entre ce bbox et un autre situé à droite.
    # Négative si l'autre commence à gauche de la fin de celui-ci
    # (chevauchement / mots collés).
    def gap_to(other : Bbox) : Float64
      other.x_min - x_max
    end

    # Deux bbox sont sur la même « ligne » si leurs intervalles
    # [y_min, y_max] se chevauchent d'au moins 50 %.
    def same_line?(other : Bbox) : Bool
      overlap = {y_max, other.y_max}.min - {y_min, other.y_min}.max
      return false if overlap <= 0
      min_height = {height, other.height}.min
      (overlap / min_height) >= 0.5
    end

    def to_h
      {
        "x_min" => x_min,
        "y_min" => y_min,
        "x_max" => x_max,
        "y_max" => y_max,
      }
    end
  end

  # Un mot extrait d'une page PDF. `text` est le contenu décodé
  # (Unicode), `bbox` sa boîte englobante, `page` l'index 1-based
  # de la page d'origine, `font_size` la taille de police effective
  # (en points), `font_name` le nom de la fonte (clé interne du
  # PDF, ex. `F0` ou `Helvetica-Bold`).
  record Word,
    text : String,
    bbox : Bbox,
    page : Int32,
    font_size : Float64,
    font_name : String do
    def to_h
      {
        "text"      => text,
        "bbox"      => bbox.to_h,
        "page"      => page,
        "font_size" => font_size,
        "font_name" => font_name,
      }
    end
  end

  # Une page PDF avec ses dimensions et la liste des mots extraits.
  record Page,
    number : Int32,
    width : Float64,
    height : Float64,
    words : Array(Word) do
    def to_h
      {
        "number" => number,
        "width"  => width,
        "height" => height,
        "words"  => words.map(&.to_h),
      }
    end
  end

  # Le contenu complet extrait d'un PDF.
  record Extract,
    source : String,
    pages : Array(Page) do
    def total_words : Int32
      pages.sum { |p| p.words.size }
    end

    def to_h
      {
        "source"      => source,
        "pages"       => pages.map(&.to_h),
        "total_words" => total_words,
      }
    end
  end
end
