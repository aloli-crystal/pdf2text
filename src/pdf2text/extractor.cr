require "compress/deflate"
require "compress/zlib"
require "./bbox"

module Pdf2Text
  # Extracteur de bbox texte natif Crystal.
  #
  # **Périmètre v0.1.0** : cible les PDFs produits par
  # `aloli-crystal/pdf` (Type1 WinAnsi encoding pour les standard
  # fonts ; CIDFont Type0 + Identity-H + ToUnicode CMap pour les
  # TTF embarqués). Les PDFs externes (Acrobat, autres
  # générateurs) peuvent ne pas être complètement supportés —
  # voir CHANGELOG pour le périmètre étendu.
  #
  # Stratégie : lecture du flux brut, repérage des objets via la
  # cross-reference table, décompression des content streams (les
  # PDFs aloli utilisent généralement FlateDecode), parsing des
  # opérateurs de texte BT/Tj/TJ/Td/TD/Tm/T*, suivi de la matrice
  # de transformation pour positionner les bbox.
  #
  # NOTE : c'est une implémentation **MINIMALE**. Beaucoup de cas
  # PDF avancés (PDF/A avec OCG, formulaires AcroForm avec champs
  # interactifs, PDFs chiffrés, etc.) ne sont pas couverts.
  module Extractor
    extend self

    class ExtractError < Exception; end

    # Extrait l'ensemble des mots positionnés d'un fichier PDF.
    def extract(path : String) : Extract
      raise ExtractError.new("file not found: #{path}") unless File.exists?(path)

      # Read raw bytes. We can't rely on UTF-8 validation since
      # PDFs interleave text and binary (compressed streams). Treat
      # the file as a byte buffer and view as String via `String.new`
      # which keeps invalid sequences as-is.
      raw_bytes = File.open(path, &.getb_to_end)
      # Header check : compare first 5 bytes against "%PDF-"
      hdr = "%PDF-".to_slice
      raise ExtractError.new("not a PDF (missing %PDF- header): #{path}") unless raw_bytes.size >= hdr.size && raw_bytes[0, hdr.size] == hdr

      objects = parse_objects(raw_bytes)
      catalog = find_catalog(objects)
      raise ExtractError.new("no /Catalog object") unless catalog

      pages_list = collect_pages(objects, catalog)
      page_extracts = pages_list.each_with_index.map do |page_obj, idx|
        extract_page(objects, page_obj, idx + 1)
      end.to_a

      Extract.new(source: path, pages: page_extracts)
    end

    # ------------------------------------------------------------
    # PDF object parser : très minimal. On scanne le fichier à la
    # recherche de séquences `<n> <gen> obj ... endobj` et on
    # indexe par numéro d'objet. Cette approche ignore la xref
    # table (qui serait plus fiable mais demande un parser plus
    # complet) ; ça marche pour les PDFs simples et déterministes.
    # ------------------------------------------------------------

    private alias ObjectMap = Hash(Int32, Bytes)

    # Scan the raw bytes looking for `<num> <gen> obj … endobj`
    # patterns. We cannot use regex on the full PDF buffer because
    # binary content streams contain bytes that are not valid UTF-8,
    # which PCRE2 rejects. So we do a manual byte scan : for each
    # " obj" sequence found, walk back to capture the object number
    # and forward to find "endobj".
    private def parse_objects(raw : Bytes) : ObjectMap
      result = ObjectMap.new
      obj_pat = "obj".to_slice
      endobj_pat = "endobj".to_slice
      i = 0
      while i <= raw.size - obj_pat.size - 1
        if obj_marker_at?(raw, i, obj_pat) && (parsed = read_object(raw, i, obj_pat, endobj_pat))
          obj_num, body, next_i = parsed
          result[obj_num] = body
          i = next_i
        else
          i += 1
        end
      end
      result
    end

    # Détecte `<whitespace>obj` à l'offset `i` (whitespace = espace,
    # newline, CR ou tab — comme le scanner d'origine).
    private def obj_marker_at?(raw : Bytes, i : Int32, obj_pat : Bytes) : Bool
      byte = raw[i]
      (byte == ' '.ord || byte == '\n'.ord || byte == '\r'.ord || byte == '\t'.ord) &&
        raw[i + 1, obj_pat.size]? == obj_pat
    end

    # Lit l'objet dont le marker `obj` est à `marker`. Retourne
    # `{numéro, corps, offset après endobj}` ou `nil` si l'en-tête
    # `<num> <gen>` est invalide ou si `endobj` est introuvable.
    private def read_object(raw : Bytes, marker : Int32, obj_pat : Bytes, endobj_pat : Bytes) : Tuple(Int32, Bytes, Int32)?
      header_start = object_header_start(raw, marker)
      header = String.new(raw[header_start..(marker - 1)]).strip
      # Expected pattern: "<obj_num> <gen>"
      parts = header.split(' ', remove_empty: true)
      return nil unless parts.size >= 2 && (obj_num = parts[0].to_i?) && parts[1].to_i?
      body_start = skip_obj_ws(raw, marker + obj_pat.size + 1)
      endobj_at = find_pattern(raw, endobj_pat, body_start)
      return nil unless endobj_at
      {obj_num, raw[body_start..(endobj_at - 1)], endobj_at + endobj_pat.size}
    end

    # Remonte jusqu'au début de la ligne d'en-tête (premier octet
    # après le newline/CR précédent).
    private def object_header_start(raw : Bytes, marker : Int32) : Int32
      j = marker - 1
      while j > 0 && raw[j] != '\n'.ord && raw[j] != '\r'.ord
        j -= 1
      end
      j + 1
    end

    # Saute les espaces/newlines/CR (PAS les tabs : conforme au
    # scanner d'origine) à partir de `pos`.
    private def skip_obj_ws(raw : Bytes, pos : Int32) : Int32
      while pos < raw.size && (raw[pos] == ' '.ord || raw[pos] == '\n'.ord || raw[pos] == '\r'.ord)
        pos += 1
      end
      pos
    end

    private def find_pattern(haystack : Bytes, needle : Bytes, start : Int32) : Int32?
      i = start
      while i <= haystack.size - needle.size
        if haystack[i, needle.size]? == needle
          return i
        end
        i += 1
      end
      nil
    end

    # Espace, newline, CR ou tab (whitespace PDF usuel).
    private def whitespace_char?(char : Char) : Bool
      char == ' ' || char == '\n' || char == '\r' || char == '\t'
    end

    private def find_catalog(objects : ObjectMap) : Bytes?
      objects.each_value do |body|
        s = String.new(body)
        return body if s.includes?("/Type") && s.includes?("/Catalog")
      end
      nil
    end

    # ------------------------------------------------------------
    # Collect pages (in order) from the catalog's /Pages tree.
    # Page tree can be a single Page or a nested /Pages object
    # with /Kids array. We do a simple recursive resolution.
    # ------------------------------------------------------------

    private def collect_pages(objects : ObjectMap, catalog : Bytes) : Array(Bytes)
      pages_root_ref = extract_ref(String.new(catalog), "/Pages")
      return [] of Bytes unless pages_root_ref
      pages_root = objects[pages_root_ref]?
      return [] of Bytes unless pages_root

      result = [] of Bytes
      walk_page_tree(objects, pages_root, result)
      result
    end

    private def walk_page_tree(objects : ObjectMap, node : Bytes, dst : Array(Bytes)) : Nil
      s = String.new(node)
      if s.includes?("/Type") && s.includes?("/Page") && !s.includes?("/Pages")
        dst << node
        return
      end
      kids = extract_array_refs(s, "/Kids")
      kids.each do |ref|
        if child = objects[ref]?
          walk_page_tree(objects, child, dst)
        end
      end
    end

    # ------------------------------------------------------------
    # Per-page extraction : find /MediaBox, /Contents, /Resources/Font
    # and parse the content stream operators.
    # ------------------------------------------------------------

    private def extract_page(objects : ObjectMap, page_body : Bytes, page_num : Int32) : Page
      s = String.new(page_body)

      media_box = extract_media_box(s) || {0.0, 0.0, 595.0, 842.0}
      page_w = media_box[2] - media_box[0]
      page_h = media_box[3] - media_box[1]

      contents_ref = extract_ref(s, "/Contents")
      words = [] of Word
      if contents_ref && (contents_obj = objects[contents_ref]?)
        font_map = build_font_map(objects, s)
        stream = decode_stream(contents_obj)
        words = parse_content_stream(stream, font_map, page_num)
      end

      Page.new(number: page_num, width: page_w, height: page_h, words: words)
    end

    private def extract_media_box(s : String) : Tuple(Float64, Float64, Float64, Float64)?
      if m = s.match(/\/MediaBox\s*\[\s*([\-0-9.]+)\s+([\-0-9.]+)\s+([\-0-9.]+)\s+([\-0-9.]+)\s*\]/)
        {m[1].to_f, m[2].to_f, m[3].to_f, m[4].to_f}
      end
    end

    private def extract_ref(s : String, key : String) : Int32?
      if m = s.match(/#{Regex.escape(key)}\s+(\d+)\s+\d+\s+R\b/)
        m[1].to_i
      end
    end

    private def extract_array_refs(s : String, key : String) : Array(Int32)
      result = [] of Int32
      if m = s.match(/#{Regex.escape(key)}\s*\[(.*?)\]/m)
        m[1].scan(/(\d+)\s+\d+\s+R\b/) do |match|
          result << match[1].to_i
        end
      end
      result
    end

    # ------------------------------------------------------------
    # Stream decoding : the PDFs we target use /FlateDecode for
    # content streams. We strip the `stream` / `endstream` markers
    # and pass the bytes through zlib.
    # ------------------------------------------------------------

    # Décode un object body (dict + stream binaire) en chaîne
    # texte. Bytes-safe : on cherche les markers via scan
    # d'octets, sans passer par `String.new` qui peut planter
    # PCRE2 si l'objet contient des bytes non-UTF8.
    #
    # Détecte automatiquement la compression FlateDecode soit
    # via la présence du token `/FlateDecode` dans le dict, soit
    # via la signature zlib `78 9C` / `78 DA` en tête du stream
    # (utile quand le dict utilise une notation alternative).
    private def decode_stream(obj_body : Bytes) : String
      stream_pat = "stream".to_slice
      endstream_pat = "endstream".to_slice
      start = find_pattern(obj_body, stream_pat, 0)
      finish = start ? find_pattern(obj_body, endstream_pat, start) : nil
      return "" unless start && finish

      data_start = skip_eol(obj_body, start + stream_pat.size)
      raw = obj_body[data_start, finish - data_start - 1]?
      return "" unless raw

      # Détecte FlateDecode :
      # 1. Par le dict `/FlateDecode` (recherche bytes-safe)
      # 2. Par la signature zlib `78 ??` (78 01, 78 9C, 78 DA)
      has_flate = find_pattern(obj_body[0, start], "/FlateDecode".to_slice, 0) != nil
      if has_flate || zlib_signature?(raw)
        inflate(raw)
      else
        String.new(raw)
      end
    end

    # Saute les newlines/CR en tête de stream (PAS les espaces :
    # conforme au décodeur d'origine).
    private def skip_eol(buf : Bytes, pos : Int32) : Int32
      while pos < buf.size && (buf[pos] == '\n'.ord || buf[pos] == '\r'.ord)
        pos += 1
      end
      pos
    end

    # Signature zlib en tête de flux : `78 01`, `78 9C` ou `78 DA`.
    private def zlib_signature?(raw : Bytes) : Bool
      raw.size >= 2 && raw[0] == 0x78_u8 && (raw[1] == 0x01_u8 || raw[1] == 0x9C_u8 || raw[1] == 0xDA_u8)
    end

    # Décompresse un flux zlib ; retombe sur les octets bruts si la
    # décompression échoue.
    private def inflate(raw : Bytes) : String
      io = IO::Memory.new(raw)
      zlib = Compress::Zlib::Reader.new(io)
      dst = IO::Memory.new
      IO.copy(zlib, dst)
      dst.to_s
    rescue
      String.new(raw)
    end

    # ------------------------------------------------------------
    # Font map : key (e.g. /F0) → {name, type, encoding, to_unicode}.
    # v0.1.0 keeps things simple : we just need the font name for
    # bookkeeping and an approximate width estimation.
    # ------------------------------------------------------------

    # Information extraite d'un dictionnaire de fonte. La `cid_map`
    # (CID 16-bit → chaîne Unicode) est construite à partir du
    # `/ToUnicode` CMap quand disponible — c'est ce qui permet de
    # décoder les strings HEX `<002500480055>` des content streams
    # CIDFont en texte lisible.
    #
    # `cid_widths` (v0.3.0) : largeur en unités texte (1/1000 em)
    # par CID, parsée depuis `/W` du DescendantFont du Type0.
    # `default_width` : `/DW` (défaut 1000) — largeur fallback
    # pour les CIDs absents de `cid_widths`.
    private class FontInfo
      property key : String
      property name : String
      property avg_advance : Float64
      property cid_map : Hash(UInt16, String)
      property byte_width : Int32 # 1 (simple) ou 2 (CID)
      property cid_widths : Hash(UInt16, Float64)
      property default_width : Float64

      def initialize(@key, @name, @avg_advance, @cid_map, @byte_width,
                     @cid_widths = Hash(UInt16, Float64).new,
                     @default_width = 1000.0)
      end

      # Largeur d'une chaîne Unicode dans cette fonte, en unités
      # texte (1/1000 em). Multiplier par font_size puis diviser
      # par 1000 pour obtenir la largeur en points PDF.
      #
      # Stratégie de fallback (v0.4.0) :
      # - Si le CID est dans `cid_widths` (parsé depuis /W) : valeur exacte.
      # - Sinon : utilise `effective_default_width` qui est la
      #   MÉDIANE des widths connues. Plus représentatif qu'un
      #   `default_width=1000` brut (= largeur d'un caractère
      #   très large alors que la médiane d'une fonte sans est
      #   typiquement ~500). Évite que les chars rares comme
      #   `→`, `…`, certaines ponctuations finales (non listés
      #   dans /W) ne soient mesurés 2× trop larges.
      def width_of(text : String) : Float64
        if cid_widths.empty?
          text.size * avg_advance
        else
          uni_to_cid = (@uni_to_cid ||= build_uni_to_cid)
          fallback = effective_default_width
          text.chars.sum(0.0) do |char|
            cid = uni_to_cid[char.to_s]?
            cid ? (cid_widths[cid]? || fallback) : fallback
          end
        end
      end

      # Largeur d'un CID BRUT (tel qu'il apparaît dans le flux de
      # contenu, avant tout décodage Unicode), en unités 1000-em.
      # C'est la mesure EXACTE : on interroge `/W` directement avec
      # le CID, sans passer par la table Unicode→CID inverse (qui
      # est lossy — plusieurs CID peuvent partager un même Unicode,
      # typiquement les variantes de chasse d'une fonte grasse).
      # Fallback médian pour les CID absents de `/W`.
      def cid_width(cid : UInt16) : Float64
        return avg_advance if cid_widths.empty?
        cid_widths[cid]? || effective_default_width
      end

      # Largeur de fallback effective : médiane des widths
      # connues. Calculée une fois et mise en cache.
      @effective_default_width : Float64?

      def effective_default_width : Float64
        @effective_default_width ||= compute_effective_default
      end

      private def compute_effective_default : Float64
        return default_width if cid_widths.empty?
        sorted = cid_widths.values.sort!
        median = sorted[sorted.size // 2]
        # On retient le MIN entre la médiane et la
        # default_width déclarée par /DW. Évite qu'un /DW
        # surdimensionné (rare mais arrive) ne fausse les bbox.
        {median, default_width}.min
      end

      @uni_to_cid : Hash(String, UInt16)?

      private def build_uni_to_cid : Hash(String, UInt16)
        h = Hash(String, UInt16).new
        cid_map.each { |cid, uni| h[uni] = cid }
        h
      end
    end

    private def build_font_map(objects : ObjectMap, page_s : String) : Hash(String, FontInfo)
      result = Hash(String, FontInfo).new
      resources_ref = extract_ref(page_s, "/Resources")
      resources_s = if resources_ref && (r = objects[resources_ref]?)
                      String.new(r)
                    else
                      page_s
                    end
      fonts_section = if m = resources_s.match(/\/Font\s*<<(.*?)>>/m)
                        m[1]
                      else
                        ""
                      end
      fonts_section.scan(/\/(\w+)\s+(\d+)\s+\d+\s+R/) do |match|
        key = "/" + match[1]
        if font = parse_font(objects, key, match[2].to_i)
          result[key] = font
        end
      end
      result
    end

    # Construit le `FontInfo` d'une fonte référencée par `font_ref`.
    # Retourne `nil` si l'objet est absent.
    private def parse_font(objects : ObjectMap, key : String, font_ref : Int32) : FontInfo?
      font_obj = objects[font_ref]?
      return nil unless font_obj
      font_s = String.new(font_obj)
      # `/BaseFont /XXX` : capturer jusqu'au prochain `/`, `>`,
      # ou espace (le `\S+` était trop gourmand et incluait
      # `/Encoding` du dict suivant).
      name = if mn = font_s.match(/\/BaseFont\s*\/([^\/\s>]+)/)
               mn[1]
             else
               "unknown"
             end
      # Détection CID font : subtype Type0 ou CIDFontType0/2
      # ⇒ strings dans le content stream sont en hex 2-byte par
      # caractère. Sinon (Type1, TrueType simple) : 1-byte.
      byte_width = (font_s.includes?("/Type0") || font_s.includes?("/CIDFontType")) ? 2 : 1
      cid_widths, default_width = parse_descendant_widths(objects, font_s)
      FontInfo.new(
        key: key,
        name: name,
        avg_advance: 500.0,
        cid_map: parse_font_cid_map(objects, font_s),
        byte_width: byte_width,
        cid_widths: cid_widths,
        default_width: default_width,
      )
    end

    # ToUnicode CMap : optionnel. Quand présent, on l'utilise pour
    # décoder les CIDs en texte Unicode ; sinon map vide.
    private def parse_font_cid_map(objects : ObjectMap, font_s : String) : Hash(UInt16, String)
      if (to_uni_ref = extract_ref(font_s, "/ToUnicode")) && (to_uni_obj = objects[to_uni_ref]?)
        parse_to_unicode_cmap(decode_stream(to_uni_obj))
      else
        Hash(UInt16, String).new
      end
    end

    # Largeurs par CID (`/W`) et largeur par défaut (`/DW`) du
    # DescendantFont d'un Type0. Valeurs par défaut si absent.
    private def parse_descendant_widths(objects : ObjectMap, font_s : String) : Tuple(Hash(UInt16, Float64), Float64)
      cid_widths = Hash(UInt16, Float64).new
      default_width = 1000.0
      descendant_refs = extract_array_refs(font_s, "/DescendantFonts")
      if (desc_ref = descendant_refs.first?) && (desc_obj = objects[desc_ref]?)
        desc_s = String.new(desc_obj)
        if mdw = desc_s.match(/\/DW\s+([\d.]+)/)
          default_width = mdw[1].to_f
        end
        cid_widths = parse_cid_widths(desc_s)
      end
      {cid_widths, default_width}
    end

    # Parse le tableau `/W` d'un DescendantFont CIDFont (Type0).
    # Format : alternance de `CID [w1 w2 ...]` (assignation aux
    # CIDs consécutifs depuis CID) ET `CID_first CID_last w`
    # (assignation uniforme à toute la range). v0.3.0 supporte
    # les deux formes.
    private def parse_cid_widths(desc_s : String) : Hash(UInt16, Float64)
      bracket = find_w_array_start(desc_s)
      return Hash(UInt16, Float64).new if bracket < 0
      interpret_w_tokens(tokenize_w_array(extract_balanced(desc_s, bracket)))
    end

    # Recherche ROBUSTE du token `/W` (tableau des largeurs par CID).
    # On exige que `/W` soit suivi — après d'éventuels espaces — d'un
    # `[`, et on itère TOUTES les occurrences de `/W` pour ignorer les
    # faux positifs :
    #   - `/WSMHES+DejaVuSans-Bold` : le préfixe de sous-ensemble de
    #     fonte (6 lettres aléatoires) peut commencer par « W ».
    #     `desc_s.index("/W")` matchait alors le BaseFont au lieu du
    #     tableau de largeurs ⇒ `cid_widths` vide ⇒ largeurs estimées
    #     au lieu d'exactes (bug : les mots des fontes dont le subset
    #     commençait par W étaient mal mesurés ; ici la fonte grasse
    #     FR, préfixe « WSMHES ») ;
    #   - `/WMode` (mode d'écriture vertical), le cas échéant.
    # Retourne l'offset du `[` ouvrant, ou -1 si introuvable.
    private def find_w_array_start(desc_s : String) : Int32
      search = 0
      while pos = desc_s.index("/W", search)
        j = pos + 2
        while j < desc_s.size && whitespace_char?(desc_s[j])
          j += 1
        end
        return j if j < desc_s.size && desc_s[j] == '['
        search = pos + 2
      end
      -1
    end

    # Retourne le contenu entre le `[` situé à `open_pos` et son `]`
    # appairé (comptage de profondeur), bornes exclues.
    private def extract_balanced(s : String, open_pos : Int32) : String
      start = open_pos + 1
      depth = 1
      i = open_pos + 1
      while i < s.size && depth > 0
        depth += 1 if s[i] == '['
        depth -= 1 if s[i] == ']'
        i += 1
      end
      s[start..(i - 2)]
    end

    # Construit la table CID → largeur à partir des tokens du `/W`.
    private def interpret_w_tokens(tokens : Array(Float64 | Array(Float64))) : Hash(UInt16, Float64)
      result = Hash(UInt16, Float64).new
      j = 0
      while j < tokens.size
        tok = tokens[j]
        unless tok.is_a?(Float64)
          j += 1
          next
        end
        j += apply_w_entry(result, tokens, j, tok)
      end
      result
    end

    # Applique une entrée `/W` à partir de l'index `j` (où `cid_start`
    # est le CID courant). Retourne le nombre de tokens consommés :
    #   - Forme 1 `cid [w1 w2 ...]` ⇒ 2 ;
    #   - Forme 2 `cid_first cid_last w` ⇒ 3 ;
    #   - token isolé non interprétable ⇒ 1.
    private def apply_w_entry(result : Hash(UInt16, Float64), tokens : Array(Float64 | Array(Float64)), j : Int32, cid_start_f : Float64) : Int32
      cid_start = cid_start_f.to_u16
      return 1 unless j + 1 < tokens.size
      nxt = tokens[j + 1]
      case nxt
      when Array(Float64)
        # Forme 1 : `cid [w1 w2 ...]`
        nxt.each_with_index do |width, k|
          result[(cid_start + k).to_u16] = width
        end
        2
      when Float64
        if j + 2 < tokens.size && (third = tokens[j + 2]).is_a?(Float64)
          # Forme 2 : `cid_first cid_last w`
          cid_end = nxt.to_u16
          (cid_start..cid_end).each { |cid| result[cid] = third }
          3
        else
          1
        end
      else
        1
      end
    end

    # Tokenizer pour le contenu de `/W [...]` : retourne une
    # liste de `Float64` (CIDs ou widths) et `Array(Float64)`
    # (les sous-tableaux `[w1 w2 ...]`).
    private def tokenize_w_array(s : String) : Array(Float64 | Array(Float64))
      result = [] of Float64 | Array(Float64)
      i = 0
      while i < s.size
        c = s[i]
        case c
        when ' ', '\n', '\r', '\t'
          i += 1
        when '['
          arr, i = read_w_subarray(s, i)
          result << arr
        else
          start = i
          while i < s.size && !{' ', '\n', '\r', '\t', '[', ']'}.includes?(s[i])
            i += 1
          end
          if val = s[start...i].to_f?
            result << val
          end
        end
      end
      result
    end

    # Lit un sous-tableau `[w1 w2 ...]` débutant au `[` situé à `open`.
    # Retourne `{largeurs, offset après le ]}`.
    private def read_w_subarray(s : String, open : Int32) : Tuple(Array(Float64), Int32)
      start = open + 1
      depth = 1
      i = open + 1
      while i < s.size && depth > 0
        depth += 1 if s[i] == '['
        depth -= 1 if s[i] == ']'
        i += 1
      end
      {s[start..(i - 2)].split.compact_map(&.to_f?), i}
    end

    # Parse un `/ToUnicode` CMap (format Adobe Identity-UCS). Gère
    # `beginbfchar`/`endbfchar` (couples individuels) et
    # `beginbfrange`/`endbfrange` (ranges). Retourne une map
    # CID 16-bit → texte Unicode (string Crystal natif).
    private def parse_to_unicode_cmap(cmap : String) : Hash(UInt16, String)
      result = Hash(UInt16, String).new
      # PCRE2 rejette les bytes UTF-8 invalides. Les CMaps peuvent
      # contenir du binaire — on filtre pour ne garder que l'ASCII
      # printable et les whitespaces avant scan, sans perte
      # d'information utile (le CMap est syntaxiquement ASCII).
      safe = String.build do |io|
        cmap.each_byte do |byte|
          if (byte >= 0x20 && byte < 0x7F) || byte == 0x0A || byte == 0x0D || byte == 0x09
            io.write_byte(byte)
          else
            io.write_byte(' '.ord.to_u8)
          end
        end
      end

      safe.scan(/beginbfchar(.*?)endbfchar/m) do |match|
        body = match[1]
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |pair|
          cid = pair[1].to_u16(16)
          uni = decode_hex_to_string(pair[2])
          result[cid] = uni
        end
      end

      safe.scan(/beginbfrange(.*?)endbfrange/m) do |match|
        body = match[1]
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |triple|
          start_cid = triple[1].to_u16(16)
          end_cid = triple[2].to_u16(16)
          start_uni = triple[3].to_i(16)
          (start_cid..end_cid).each_with_index do |cid, i|
            result[cid] = (start_uni + i).chr.to_s
          end
        end
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*\[\s*((?:<[0-9A-Fa-f]+>\s*)+)\]/) do |arr|
          start_cid = arr[1].to_u16(16)
          unis = [] of String
          arr[3].scan(/<([0-9A-Fa-f]+)>/) { |hex_match| unis << decode_hex_to_string(hex_match[1]) }
          unis.each_with_index do |uni, i|
            result[start_cid + i] = uni
          end
        end
      end

      result
    end

    # Décode une chaîne hex (`004C0065`) en texte Unicode. Chaque
    # paire de 4 hex digits = 1 codepoint BMP. Pour les caractères
    # hors BMP, le PDF utilise des paires de surrogates UTF-16 que
    # nous combinons.
    private def decode_hex_to_string(hex : String) : String
      String.build do |io|
        i = 0
        while i + 4 <= hex.size
          cp = hex[i, 4].to_i(16)
          if cp >= 0xD800 && cp <= 0xDBFF && i + 8 <= hex.size
            # High surrogate, lire la low surrogate suivante
            low = hex[i + 4, 4].to_i(16)
            if low >= 0xDC00 && low <= 0xDFFF
              full = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
              io << full.chr
              i += 8
              next
            end
          end
          io << cp.chr
          i += 4
        end
      end
    end

    # ------------------------------------------------------------
    # Content stream operator parser. We track :
    # - text matrix (Tm, Td, TD, T*)
    # - current font + size (Tf)
    # - text emission (Tj, TJ)
    # ------------------------------------------------------------

    # État de texte courant pendant le parcours du content stream :
    # position (tx/ty), matrice de ligne (tlm_x/tlm_y, pour T*),
    # fonte et taille actives, et drapeau BT/ET.
    private class TextState
      property tx = 0.0
      property ty = 0.0
      property tlm_x = 0.0
      property tlm_y = 0.0
      property font_key = ""
      property font_size = 12.0
      property? in_text = false
    end

    private def parse_content_stream(stream : String, fonts : Hash(String, FontInfo), page_num : Int32) : Array(Word)
      words = [] of Word
      state = TextState.new
      operands = [] of String
      # Stratégie : on itère les tokens ; chaque opérateur consomme
      # ses opérandes accumulés, le reste est empilé comme opérande.
      tokenize(stream).each do |tok|
        if apply_operator(state, tok, operands, words, fonts, page_num)
          operands.clear
        else
          # Token non-opérateur : nombre ou string `(...)` / `<...>`.
          operands << tok
        end
      end
      words
    end

    # Applique un opérateur de texte à l'état. Retourne `true` si
    # `tok` était bien un opérateur (les opérandes seront vidés),
    # `false` s'il s'agit d'un opérande à empiler.
    private def apply_operator(state : TextState, tok : String, operands : Array(String), words : Array(Word), fonts : Hash(String, FontInfo), page_num : Int32) : Bool
      case tok
      when "BT", "ET"             then toggle_text(state, tok)
      when "Tf"                   then set_font(state, operands)
      when "Tm", "Td", "TD", "T*" then move_cursor(state, tok, operands)
      when "Tj", "TJ"             then show_text(state, tok, operands, words, fonts, page_num)
      when "q", "Q"
        # Sauvegarde/restauration d'état graphique. On ne suit pas la
        # CTM : les pages pivotées/scalées n'auront pas de bbox exacte.
      else
        return false
      end
      true
    end

    # BT : ouvre un bloc texte et réinitialise la position. ET : ferme.
    private def toggle_text(state : TextState, tok : String) : Nil
      case tok
      when "BT"
        state.in_text = true
        state.tx = 0.0
        state.ty = 0.0
        state.tlm_x = 0.0
        state.tlm_y = 0.0
      when "ET"
        state.in_text = false
      end
    end

    # Tf : `font_key font_size Tf`.
    private def set_font(state : TextState, operands : Array(String)) : Nil
      return unless operands.size >= 2
      state.font_key = operands[-2]
      state.font_size = operands[-1].to_f? || 12.0
    end

    # Aiguille les opérateurs de positionnement Tm/Td/TD/T*.
    private def move_cursor(state : TextState, tok : String, operands : Array(String)) : Nil
      case tok
      when "Tm"       then set_matrix(state, operands)
      when "Td", "TD" then translate_line(state, operands)
      when "T*"       then next_line(state)
      end
    end

    # Tm : `a b c d e f Tm` (seuls e=x, f=y comptent pour la position).
    private def set_matrix(state : TextState, operands : Array(String)) : Nil
      return unless operands.size >= 6
      state.tx = operands[-2].to_f? || 0.0
      state.ty = operands[-1].to_f? || 0.0
      state.tlm_x = state.tx
      state.tlm_y = state.ty
    end

    # Td/TD : translation de la ligne de texte.
    private def translate_line(state : TextState, operands : Array(String)) : Nil
      return unless operands.size >= 2
      dx = operands[-2].to_f? || 0.0
      dy = operands[-1].to_f? || 0.0
      state.tlm_x += dx
      state.tlm_y += dy
      state.tx = state.tlm_x
      state.ty = state.tlm_y
    end

    # T* : ligne suivante au leading par défaut (approximé par font_size).
    private def next_line(state : TextState) : Nil
      state.tlm_y -= state.font_size
      state.tx = state.tlm_x
      state.ty = state.tlm_y
    end

    # Tj / TJ : émission de texte positionné.
    private def show_text(state : TextState, tok : String, operands : Array(String), words : Array(Word), fonts : Hash(String, FontInfo), page_num : Int32) : Nil
      return unless (operand = operands.last?) && state.in_text?
      font = fonts[state.font_key]?
      case tok
      when "Tj"
        # operand : (text) or <hex>
        state.tx = emit_string(words, operand, font, state.tx, state, page_num)
      when "TJ"
        # operand : [ (text) num (text) num ... ] or [ <hex> num ... ]
        state.tx = emit_tj_array(words, operand, font, state, page_num)
      end
    end

    # Décode une string à l'abscisse `x`, émet ses mots et retourne la
    # nouvelle abscisse (ty/font_size lus dans l'état).
    private def emit_string(words : Array(Word), str : String, font : FontInfo?, x : Float64, state : TextState, page_num : Int32) : Float64
      text, cw = decode_with_widths(str, font)
      return x if text.empty?
      words.concat split_into_words(text, cw, x, state.ty, state.font_size, page_num, font.try(&.name) || "?")
      x + cw.sum * state.font_size / 1000.0
    end

    # Parcourt un tableau TJ (strings + déplacements) et retourne la
    # nouvelle abscisse.
    private def emit_tj_array(words : Array(Word), arr : String, font : FontInfo?, state : TextState, page_num : Int32) : Float64
      tx = state.tx
      parse_tj_array(arr).each do |elt|
        case elt
        when String
          tx = emit_string(words, elt, font, tx, state, page_num)
        when Float64
          tx += -elt * state.font_size / 1000.0
        end
      end
      tx
    end

    # Tokenize PDF content stream into operators and operands.
    # Strings `(abc)` are kept as one token (including parens),
    # arrays `[...]` likewise, hex strings `<...>` likewise.
    private def tokenize(s : String) : Array(String)
      result = [] of String
      i = 0
      while i < s.size
        c = s[i]
        case c
        when ' ', '\n', '\r', '\t'
          i += 1
        when '('
          tok, i = scan_paren(s, i)
          result << tok
        when '['
          tok, i = scan_bracket(s, i)
          result << tok
        when '<'
          tok, i = scan_angle(s, i)
          result << tok
        else
          tok, i = scan_bare(s, i)
          result << tok
        end
      end
      result
    end

    # Lit une string parenthésée `(...)` (parens équilibrées, échappements
    # gérés) débutant à `start`. Retourne `{token, offset suivant}`.
    private def scan_paren(s : String, start : Int32) : Tuple(String, Int32)
      depth = 1
      i = start + 1
      while i < s.size && depth > 0
        cc = s[i]
        if cc == '\\' && i + 1 < s.size
          i += 2
          next
        end
        depth += 1 if cc == '('
        depth -= 1 if cc == ')'
        i += 1
      end
      {s[start...i], i}
    end

    # Lit un tableau `[...]` (crochets équilibrés) débutant à `start`.
    private def scan_bracket(s : String, start : Int32) : Tuple(String, Int32)
      depth = 1
      i = start + 1
      while i < s.size && depth > 0
        cc = s[i]
        if cc == '\\' && i + 1 < s.size
          i += 2
          next
        end
        depth += 1 if cc == '['
        depth -= 1 if cc == ']'
        i += 1
      end
      {s[start...i], i}
    end

    # Lit un token débutant par `<` : string hex `<...>` ou dict `<<...>>`.
    private def scan_angle(s : String, start : Int32) : Tuple(String, Int32)
      if start + 1 < s.size && s[start + 1] == '<'
        scan_dict(s, start)
      else
        scan_hex(s, start)
      end
    end

    # Lit un dictionnaire `<<...>>` (imbrication équilibrée).
    private def scan_dict(s : String, start : Int32) : Tuple(String, Int32)
      depth = 1
      i = start + 2
      while i < s.size && depth > 0
        if i + 1 < s.size && s[i] == '<' && s[i + 1] == '<'
          depth += 1; i += 2; next
        elsif i + 1 < s.size && s[i] == '>' && s[i + 1] == '>'
          depth -= 1; i += 2; next
        end
        i += 1
      end
      {s[start...i], i}
    end

    # Lit une string hex `<...>` jusqu'au `>`.
    private def scan_hex(s : String, start : Int32) : Tuple(String, Int32)
      i = start + 1
      while i < s.size && s[i] != '>'
        i += 1
      end
      i += 1 if i < s.size
      {s[start...i], i}
    end

    # Lit un token « nu » (opérateur ou nombre) jusqu'au prochain
    # whitespace ou délimiteur `( [ <`.
    private def scan_bare(s : String, start : Int32) : Tuple(String, Int32)
      i = start
      while i < s.size && ![' ', '\n', '\r', '\t', '(', '[', '<'].includes?(s[i])
        i += 1
      end
      {s[start...i], i}
    end

    # Decode a PDF literal string `(abc\nde)` into a Crystal String.
    # v0.1.0 keeps things in WinAnsi-ish : we map most chars as-is.
    # Décode une string PDF en texte Unicode. Reconnaît :
    #   - String parenthésée `(abc\ndef)` (escape octal + backslash)
    #   - String hex `<00450046>` (chaque paire de hex = 1 byte ; si
    #     `font.byte_width == 2`, chaque CID = 2 bytes, lookup dans
    #     `font.cid_map` ; si byte_width == 1, on prend juste le byte
    #     comme codepoint Latin-1).
    private def decode_string(s : String, font : FontInfo? = nil) : String
      if s.starts_with?('<') && s.ends_with?('>')
        decode_hex_string(s, font)
      elsif s.starts_with?('(') && s.ends_with?(')')
        decode_paren_string(s)
      else
        ""
      end
    end

    # Décode une string PDF en renvoyant À LA FOIS le texte Unicode
    # ET la largeur de chaque caractère (en unités 1000-em), mesurée
    # depuis le CID BRUT du flux via `/W` — sans le détour
    # Unicode→CID inverse de `width_of`, qui sous-estime les fontes
    # dont plusieurs CID partagent un Unicode (cas typique du gras :
    # `width_of` retombait sur la médiane pour des glyphes pourtant
    # listés dans `/W`, mesurant les mots gras ~25 % trop étroits ⇒
    # faux positifs `huge_gap` dans pdf-audit).
    #
    # Le tableau de largeurs est PARALLÈLE aux caractères du texte.
    # Quand un CID se décode en plusieurs caractères (ligature
    # `ﬁ`→`fi`), la largeur du CID est portée par le 1ᵉʳ caractère
    # et 0 par les suivants — la somme par mot reste exacte.
    private def decode_with_widths(s : String, font : FontInfo?) : Tuple(String, Array(Float64))
      widths = [] of Float64
      if s.starts_with?('<') && s.ends_with?('>')
        text = decode_hex_with_widths(s, font, widths)
        {text, widths}
      elsif s.starts_with?('(') && s.ends_with?(')')
        # Fonte simple (mono-octet) : on décode le texte puis on
        # mesure chaque caractère via le fallback de la fonte
        # (cid_widths vide ⇒ avg_advance). Suffisant pour les
        # fontes de base ; les CIDFonts passent par le chemin hex.
        text = decode_paren_string(s)
        fb = font.try(&.avg_advance) || 500.0
        text.each_char { widths << fb }
        {text, widths}
      else
        {"", widths}
      end
    end

    # Comme `decode_hex_string`, mais remplit aussi `widths` avec la
    # largeur (1000-em) de chaque caractère émis, mesurée par CID.
    # Convertit une string hex PDF `<...>` en octets (whitespace
    # ignoré, padding `0` si longueur impaire).
    private def hex_to_bytes(s : String) : Array(UInt8)
      hex = s[1..-2].gsub(/\s+/, "")
      hex += "0" if hex.size.odd?
      bytes = [] of UInt8
      i = 0
      while i + 2 <= hex.size
        bytes << hex[i, 2].to_u8(16)
        i += 2
      end
      bytes
    end

    # Lit un CID à l'index `idx` : 2 octets si `byte_width == 2` et
    # qu'une paire complète est disponible, sinon 1 octet. Retourne
    # `{cid, nombre d'octets consommés}`.
    private def read_cid(bytes : Array(UInt8), idx : Int32, byte_width : Int32) : Tuple(UInt16, Int32)
      if byte_width == 2 && idx + 1 < bytes.size
        {((bytes[idx].to_u16 << 8) | bytes[idx + 1].to_u16), 2}
      else
        {bytes[idx].to_u16, 1}
      end
    end

    private def decode_hex_with_widths(s : String, font : FontInfo?, widths : Array(Float64)) : String
      bytes = hex_to_bytes(s)
      byte_width = font.try(&.byte_width) || 1
      cid_map = font.try(&.cid_map)

      String.build do |io|
        idx = 0
        while idx < bytes.size
          cid, consumed = read_cid(bytes, idx, byte_width)
          idx += consumed
          uni = (cid_map && cid_map[cid]?) || (cid < 0x10000 ? cid.chr.to_s : "")
          w = font.try(&.cid_width(cid)) || 0.0
          # 1ʳᵉ position reçoit la largeur du CID, les suivantes 0.
          first = true
          uni.each_char do |char|
            io << char
            widths << (first ? w : 0.0)
            first = false
          end
        end
      end
    end

    private def decode_hex_string(s : String, font : FontInfo?) : String
      bytes = hex_to_bytes(s)
      byte_width = font.try(&.byte_width) || 1
      cid_map = font.try(&.cid_map)

      String.build do |io|
        idx = 0
        while idx < bytes.size
          cid, consumed = read_cid(bytes, idx, byte_width)
          idx += consumed
          if cid_map && (uni = cid_map[cid]?)
            io << uni
          elsif consumed == 1 || cid < 0x10000
            # Fallback : si pas de CMap, on émet le CID brut comme
            # Latin-1 (rarement correct mais limite la perte d'info).
            io << cid.chr
          end
        end
      end
    end

    private def decode_paren_string(s : String) : String
      body = s[1..-2]
      String.build do |io|
        i = 0
        while i < body.size
          c = body[i]
          if c == '\\' && i + 1 < body.size
            i = decode_escape(body, i, io)
          else
            io << c
            i += 1
          end
        end
      end
    end

    # Décode une séquence d'échappement débutant au backslash `i`,
    # écrit le caractère dans `io` et retourne l'offset suivant.
    private def decode_escape(body : String, i : Int32, io : IO) : Int32
      nc = body[i + 1]
      if mapped = simple_escape(nc)
        io << mapped
        i + 2
      elsif nc.in?('0'..'7')
        read_octal_escape(body, i, io)
      else
        io << nc
        i + 2
      end
    end

    # Échappements PDF à un caractère (`\n`, `\t`, `\(`, …). Retourne
    # `nil` pour les séquences non simples (octales / inconnues).
    private def simple_escape(nc : Char) : Char?
      case nc
      when 'n'  then '\n'
      when 'r'  then '\r'
      when 't'  then '\t'
      when 'b'  then '\b'
      when 'f'  then '\f'
      when '('  then '('
      when ')'  then ')'
      when '\\' then '\\'
      else           nil
      end
    end

    # Échappement octal `\ooo` (1 à 3 chiffres). Écrit le caractère et
    # retourne l'offset après le dernier chiffre octal consommé.
    private def read_octal_escape(body : String, i : Int32, io : IO) : Int32
      j = i + 1
      val = 0
      while j < body.size && j < i + 4 && body[j].in?('0'..'7')
        val = val * 8 + (body[j].ord - '0'.ord)
        j += 1
      end
      io << val.chr
      j
    end

    # Parse a TJ array's content (between `[` and `]`).
    # Supporte les strings parenthésées `(abc)` ET hex `<00450046>`,
    # ainsi que les nombres de positionnement.
    private def parse_tj_array(arr : String) : Array(String | Float64)
      result = [] of String | Float64
      return result unless arr.starts_with?('[') && arr.ends_with?(']')
      body = arr[1..-2]
      i = 0
      while i < body.size
        c = body[i]
        case c
        when ' ', '\n', '\r', '\t'
          i += 1
        when '('
          tok, i = scan_paren(body, i)
          result << tok
        when '<'
          tok, i = scan_hex(body, i)
          result << tok
        else
          tok, i = scan_tj_token(body, i)
          if val = tok.to_f?
            result << val
          end
        end
      end
      result
    end

    # Lit un token « nu » d'un tableau TJ (nombre de positionnement)
    # jusqu'au prochain whitespace ou délimiteur `( <`.
    private def scan_tj_token(body : String, start : Int32) : Tuple(String, Int32)
      i = start
      while i < body.size && ![' ', '\n', '\r', '\t', '(', '<'].includes?(body[i])
        i += 1
      end
      {body[start...i], i}
    end

    # Rendered width of a text in PDF points. Uses the font's
    # per-CID widths (parsed from `/W`) when available, falling
    # back to `avg_advance` otherwise. PDF convention : font
    # units are 1/1000 of em, so we divide by 1000 after scaling
    # by font_size.
    private def estimate_width(text : String, font_size : Float64, font : FontInfo?) : Float64
      if font && !font.cid_widths.empty?
        font.width_of(text) * font_size / 1000.0
      else
        advance = font.try(&.avg_advance) || 500.0
        text.size * advance * font_size / 1000.0
      end
    end

    # Split a positioned text string into individual words by ASCII
    # space, and produce a `Word` for each non-empty fragment.
    # Each word's bbox is approximated from the position and an
    # estimated width.
    # Découpe un run de texte en mots (séparés par l'espace ASCII)
    # avec des bbox EXACTES, en s'appuyant sur la largeur réelle de
    # chaque caractère (`char_widths`, en unités 1000-em, parallèle
    # aux caractères de `text`). Chaque mot avance le curseur de la
    # somme des largeurs de ses caractères (× font_size / 1000).
    #
    # Avant v0.5.0, on répartissait `total_width / text.size`
    # uniformément par caractère — approximation grossière pour une
    # fonte proportionnelle, et a fortiori fausse quand la largeur
    # totale elle-même était mal estimée (gras). Désormais chaque
    # glyphe a sa vraie chasse.
    private def split_into_words(text : String, char_widths : Array(Float64), x : Float64, y : Float64, font_size : Float64, page_num : Int32, font_name : String) : Array(Word)
      result = [] of Word
      return result if text.strip.empty?

      scale = font_size / 1000.0
      chars = text.chars
      cursor = x
      word_start_x = x
      buf = String::Builder.new
      buf_empty = true

      flush = -> {
        unless buf_empty
          part = buf.to_s
          unless part.empty?
            result << Word.new(
              text: part,
              bbox: Bbox.new(x_min: word_start_x, y_min: y, x_max: cursor, y_max: y + font_size),
              page: page_num,
              font_size: font_size,
              font_name: font_name,
            )
          end
        end
        buf = String::Builder.new
        buf_empty = true
      }

      chars.each_with_index do |char, i|
        w = (char_widths[i]? || 0.0) * scale
        if char == ' '
          flush.call
          cursor += w
          word_start_x = cursor
        else
          if buf_empty
            word_start_x = cursor
            buf_empty = false
          end
          buf << char
          cursor += w
        end
      end
      flush.call
      result
    end
  end
end
