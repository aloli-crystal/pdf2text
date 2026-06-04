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
      raw_bytes = File.open(path) { |f| f.getb_to_end }
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
      i = 0
      space = ' '.ord.to_u8
      newline = '\n'.ord.to_u8
      cr = '\r'.ord.to_u8
      tab = '\t'.ord.to_u8
      obj_pat = "obj".to_slice
      endobj_pat = "endobj".to_slice

      while i <= raw.size - obj_pat.size - 1
        # Look for " obj" preceded by whitespace
        if (raw[i] == space || raw[i] == newline || raw[i] == cr || raw[i] == tab) &&
           raw[i + 1, obj_pat.size]? == obj_pat
          # Walk back to find the start of the line/header
          j = i - 1
          while j > 0 && raw[j] != newline && raw[j] != cr
            j -= 1
          end
          header = String.new(raw[(j + 1)..(i - 1)]).strip
          # Expected pattern: "<obj_num> <gen>"
          parts = header.split(' ', remove_empty: true)
          if parts.size >= 2 && (obj_num = parts[0].to_i?) && parts[1].to_i?
            body_start = i + obj_pat.size + 1
            # Skip whitespace
            while body_start < raw.size && (raw[body_start] == space || raw[body_start] == newline || raw[body_start] == cr)
              body_start += 1
            end
            # Find "endobj"
            if (endobj_at = find_pattern(raw, endobj_pat, body_start))
              result[obj_num] = raw[body_start..(endobj_at - 1)]
              i = endobj_at + endobj_pat.size
              next
            end
          end
        end
        i += 1
      end
      result
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
        if (child = objects[ref]?)
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
      if (m = s.match(/\/MediaBox\s*\[\s*([\-0-9.]+)\s+([\-0-9.]+)\s+([\-0-9.]+)\s+([\-0-9.]+)\s*\]/))
        {m[1].to_f, m[2].to_f, m[3].to_f, m[4].to_f}
      end
    end

    private def extract_ref(s : String, key : String) : Int32?
      if (m = s.match(/#{Regex.escape(key)}\s+(\d+)\s+\d+\s+R\b/))
        m[1].to_i
      end
    end

    private def extract_array_refs(s : String, key : String) : Array(Int32)
      result = [] of Int32
      if (m = s.match(/#{Regex.escape(key)}\s*\[(.*?)\]/m))
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

      data_start = start + stream_pat.size
      while data_start < obj_body.size && (obj_body[data_start] == '\n'.ord || obj_body[data_start] == '\r'.ord)
        data_start += 1
      end
      raw = obj_body[data_start, finish - data_start - 1]?
      return "" unless raw

      # Détecte FlateDecode :
      # 1. Par le dict `/FlateDecode` (recherche bytes-safe)
      # 2. Par la signature zlib `78 ??` (78 01, 78 9C, 78 DA)
      dict_part = obj_body[0, start]
      has_flate = find_pattern(dict_part, "/FlateDecode".to_slice, 0) != nil
      zlib_sig = raw.size >= 2 && raw[0] == 0x78_u8 && (raw[1] == 0x01_u8 || raw[1] == 0x9C_u8 || raw[1] == 0xDA_u8)

      if has_flate || zlib_sig
        begin
          io = IO::Memory.new(raw)
          zlib = Compress::Zlib::Reader.new(io)
          dst = IO::Memory.new
          IO.copy(zlib, dst)
          dst.to_s
        rescue
          String.new(raw)
        end
      else
        String.new(raw)
      end
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
      def width_of(text : String) : Float64
        if cid_widths.empty?
          # Fallback : moyenne approximative pour les fontes
          # simples sans /W parsé.
          text.size * avg_advance
        else
          # Reverse-lookup via cid_map : pour chaque char Unicode,
          # trouver son CID et sa width.
          # Construit un cache inverse à la première utilisation.
          @uni_to_cid ||= build_uni_to_cid
          text.chars.sum(0.0) do |c|
            cid = @uni_to_cid.not_nil![c.to_s]?
            cid ? (cid_widths[cid]? || default_width) : default_width
          end
        end
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
      fonts_section = if (m = resources_s.match(/\/Font\s*<<(.*?)>>/m))
                        m[1]
                      else
                        ""
                      end
      fonts_section.scan(/\/(\w+)\s+(\d+)\s+\d+\s+R/) do |match|
        key = "/" + match[1]
        font_ref = match[2].to_i
        if (font_obj = objects[font_ref]?)
          font_s = String.new(font_obj)
          # `/BaseFont /XXX` : capturer jusqu'au prochain `/`, `>`,
          # ou espace (le `\S+` était trop gourmand et incluait
          # `/Encoding` du dict suivant).
          name = if (mn = font_s.match(/\/BaseFont\s*\/([^\/\s>]+)/))
                   mn[1]
                 else
                   "unknown"
                 end
          # Détection CID font : subtype Type0 ou CIDFontType0/2
          # ⇒ strings dans le content stream sont en hex 2-byte par
          # caractère. Sinon (Type1, TrueType simple) : 1-byte.
          byte_width = (font_s.includes?("/Type0") || font_s.includes?("/CIDFontType")) ? 2 : 1
          # ToUnicode CMap : optionnel. Quand présent, on l'utilise
          # pour décoder les CIDs en texte Unicode.
          cid_map = Hash(UInt16, String).new
          if (to_uni_ref = extract_ref(font_s, "/ToUnicode")) && (to_uni_obj = objects[to_uni_ref]?)
            cmap_stream = decode_stream(to_uni_obj)
            cid_map = parse_to_unicode_cmap(cmap_stream)
          end
          # /W : per-CID widths du DescendantFont (Type0 -> CIDFont)
          cid_widths = Hash(UInt16, Float64).new
          default_width = 1000.0
          descendant_refs = extract_array_refs(font_s, "/DescendantFonts")
          if (desc_ref = descendant_refs.first?) && (desc_obj = objects[desc_ref]?)
            desc_s = String.new(desc_obj)
            if (mdw = desc_s.match(/\/DW\s+([\d.]+)/))
              default_width = mdw[1].to_f
            end
            cid_widths = parse_cid_widths(desc_s)
          end
          result[key] = FontInfo.new(
            key: key,
            name: name,
            avg_advance: 500.0,
            cid_map: cid_map,
            byte_width: byte_width,
            cid_widths: cid_widths,
            default_width: default_width,
          )
        end
      end
      result
    end

    # Parse le tableau `/W` d'un DescendantFont CIDFont (Type0).
    # Format : alternance de `CID [w1 w2 ...]` (assignation aux
    # CIDs consécutifs depuis CID) ET `CID_first CID_last w`
    # (assignation uniforme à toute la range). v0.3.0 supporte
    # les deux formes.
    private def parse_cid_widths(desc_s : String) : Hash(UInt16, Float64)
      result = Hash(UInt16, Float64).new
      # Le `/W [...]` peut être très long, on capture jusqu'au `]`
      # de plus haut niveau via comptage de profondeur manuel.
      idx = desc_s.index("/W")
      return result unless idx
      # Skip whitespace puis trouver le `[`
      i = idx + 2
      while i < desc_s.size && desc_s[i] != '['
        return result if desc_s[i] != ' ' && desc_s[i] != '\n' && desc_s[i] != '\r' && desc_s[i] != '\t'
        i += 1
      end
      return result unless i < desc_s.size
      start = i + 1
      depth = 1
      i += 1
      while i < desc_s.size && depth > 0
        depth += 1 if desc_s[i] == '['
        depth -= 1 if desc_s[i] == ']'
        i += 1
      end
      body = desc_s[start..(i - 2)]

      tokens = tokenize_w_array(body)
      j = 0
      while j < tokens.size
        tok = tokens[j]
        case tok
        when Float64
          cid_start = tok.to_u16
          if j + 1 < tokens.size
            nxt = tokens[j + 1]
            case nxt
            when Array(Float64)
              # Forme 1 : `cid [w1 w2 ...]`
              nxt.each_with_index do |w, k|
                result[(cid_start + k).to_u16] = w
              end
              j += 2
            when Float64
              if j + 2 < tokens.size && (third = tokens[j + 2]).is_a?(Float64)
                # Forme 2 : `cid_first cid_last w`
                cid_end = nxt.to_u16
                w = third
                (cid_start..cid_end).each { |c| result[c] = w }
                j += 3
              else
                j += 1
              end
            else
              j += 1
            end
          else
            j += 1
          end
        else
          j += 1
        end
      end
      result
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
          start = i + 1
          depth = 1
          i += 1
          while i < s.size && depth > 0
            depth += 1 if s[i] == '['
            depth -= 1 if s[i] == ']'
            i += 1
          end
          inner = s[start..(i - 2)]
          arr = inner.split.compact_map(&.to_f?)
          result << arr
        else
          start = i
          while i < s.size && !{' ', '\n', '\r', '\t', '[', ']'}.includes?(s[i])
            i += 1
          end
          tok = s[start...i]
          if (val = tok.to_f?)
            result << val
          end
        end
      end
      result
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
        cmap.each_byte do |b|
          if (b >= 0x20 && b < 0x7F) || b == 0x0A || b == 0x0D || b == 0x09
            io.write_byte(b)
          else
            io.write_byte(' '.ord.to_u8)
          end
        end
      end

      safe.scan(/beginbfchar(.*?)endbfchar/m) do |m|
        body = m[1]
        body.scan(/<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>/) do |pair|
          cid = pair[1].to_u16(16)
          uni = decode_hex_to_string(pair[2])
          result[cid] = uni
        end
      end

      safe.scan(/beginbfrange(.*?)endbfrange/m) do |m|
        body = m[1]
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
          arr[3].scan(/<([0-9A-Fa-f]+)>/) { |um| unis << decode_hex_to_string(um[1]) }
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

    private def parse_content_stream(stream : String, fonts : Hash(String, FontInfo), page_num : Int32) : Array(Word)
      words = [] of Word
      # Text state
      tx = 0.0
      ty = 0.0
      tlm_x = 0.0 # text line matrix x (for T*)
      tlm_y = 0.0
      font_key = ""
      font_size = 12.0
      in_text = false

      # Tokenize the stream. Each PDF token is whitespace-separated
      # except for strings `(...)` and arrays `[...]` and dicts
      # `<<...>>`. For our limited needs we use a regex-based scan
      # which is much simpler than a real tokenizer.
      # Strategy : iterate over operators; for each operator, look
      # back to find its operands.
      tokens = tokenize(stream)
      operands = [] of String

      tokens.each do |tok|
        case tok
        when "BT"
          in_text = true
          tx = 0.0
          ty = 0.0
          tlm_x = 0.0
          tlm_y = 0.0
          operands.clear
        when "ET"
          in_text = false
          operands.clear
        when "Tf"
          # operands : font_key  font_size
          if operands.size >= 2
            font_key = operands[-2]
            font_size = operands[-1].to_f? || 12.0
          end
          operands.clear
        when "Tm"
          # operands : a b c d e f (only e=x, f=y matter for position)
          if operands.size >= 6
            tx = operands[-2].to_f? || 0.0
            ty = operands[-1].to_f? || 0.0
            tlm_x = tx
            tlm_y = ty
          end
          operands.clear
        when "Td", "TD"
          if operands.size >= 2
            dx = operands[-2].to_f? || 0.0
            dy = operands[-1].to_f? || 0.0
            tlm_x += dx
            tlm_y += dy
            tx = tlm_x
            ty = tlm_y
          end
          operands.clear
        when "T*"
          # next line at default leading (we approximate with font_size)
          tlm_y -= font_size
          tx = tlm_x
          ty = tlm_y
          operands.clear
        when "Tj"
          # operand : (text) or <hex>
          if (str = operands.last?) && in_text
            current_font = fonts[font_key]?
            text = decode_string(str, current_font)
            unless text.empty?
              w = estimate_width(text, font_size, current_font)
              words.concat split_into_words(text, tx, ty, font_size, w, page_num, current_font.try(&.name) || "?")
              tx += w
            end
          end
          operands.clear
        when "TJ"
          # operand : [ (text) num (text) num ... ] or [ <hex> num ... ]
          if (arr = operands.last?) && in_text
            current_font = fonts[font_key]?
            elts = parse_tj_array(arr)
            elts.each do |elt|
              case elt
              when String
                text = decode_string(elt, current_font)
                unless text.empty?
                  w = estimate_width(text, font_size, current_font)
                  words.concat split_into_words(text, tx, ty, font_size, w, page_num, current_font.try(&.name) || "?")
                  tx += w
                end
              when Float64
                tx += -elt * font_size / 1000.0
              end
            end
          end
          operands.clear
        when "q", "Q"
          # Graphics state save/restore. We don't track CTM properly;
          # this means rotated/scaled pages won't have correct bbox.
          operands.clear
        else
          # Treat as operand (number or string starting with `(` or `<`)
          operands << tok
        end
      end

      words
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
          # Balanced parens, handle escapes
          start = i
          depth = 1
          i += 1
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
          result << s[start...i]
        when '['
          start = i
          depth = 1
          i += 1
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
          result << s[start...i]
        when '<'
          # Hex string `<...>` or dict `<<...>>`
          if i + 1 < s.size && s[i + 1] == '<'
            start = i
            depth = 1
            i += 2
            while i < s.size && depth > 0
              if i + 1 < s.size && s[i] == '<' && s[i + 1] == '<'
                depth += 1; i += 2; next
              elsif i + 1 < s.size && s[i] == '>' && s[i + 1] == '>'
                depth -= 1; i += 2; next
              end
              i += 1
            end
            result << s[start...i]
          else
            start = i
            i += 1
            while i < s.size && s[i] != '>'
              i += 1
            end
            i += 1 if i < s.size
            result << s[start...i]
          end
        else
          start = i
          while i < s.size && ![' ', '\n', '\r', '\t', '(', '[', '<'].includes?(s[i])
            i += 1
          end
          result << s[start...i]
        end
      end
      result
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

    private def decode_hex_string(s : String, font : FontInfo?) : String
      hex = s[1..-2].gsub(/\s+/, "")
      # Pad if odd
      hex += "0" if hex.size.odd?
      bytes = [] of UInt8
      i = 0
      while i + 2 <= hex.size
        bytes << hex[i, 2].to_u8(16)
        i += 2
      end

      byte_width = font.try(&.byte_width) || 1
      cid_map = font.try(&.cid_map)

      String.build do |io|
        idx = 0
        while idx < bytes.size
          if byte_width == 2 && idx + 1 < bytes.size
            cid = (bytes[idx].to_u16 << 8) | bytes[idx + 1].to_u16
            if cid_map && (uni = cid_map[cid]?)
              io << uni
            else
              # Fallback : si pas de CMap, on émet le CID brut comme
              # Latin-1 (rarement correct mais limite la perte d'info).
              io << cid.chr if cid < 0x10000
            end
            idx += 2
          else
            byte = bytes[idx]
            if cid_map && (uni = cid_map[byte.to_u16]?)
              io << uni
            else
              io << byte.chr
            end
            idx += 1
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
            nc = body[i + 1]
            case nc
            when 'n'  then io << '\n'; i += 2
            when 'r'  then io << '\r'; i += 2
            when 't'  then io << '\t'; i += 2
            when 'b'  then io << '\b'; i += 2
            when 'f'  then io << '\f'; i += 2
            when '('  then io << '('; i += 2
            when ')'  then io << ')'; i += 2
            when '\\' then io << '\\'; i += 2
            when '0'..'7'
              j = i + 1
              val = 0
              while j < body.size && j < i + 4 && body[j].in?('0'..'7')
                val = val * 8 + (body[j].ord - '0'.ord)
                j += 1
              end
              io << val.chr
              i = j
            else
              io << nc; i += 2
            end
          else
            io << c
            i += 1
          end
        end
      end
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
          start = i
          depth = 1
          i += 1
          while i < body.size && depth > 0
            cc = body[i]
            if cc == '\\' && i + 1 < body.size
              i += 2
              next
            end
            depth += 1 if cc == '('
            depth -= 1 if cc == ')'
            i += 1
          end
          result << body[start...i]
        when '<'
          start = i
          i += 1
          while i < body.size && body[i] != '>'
            i += 1
          end
          i += 1 if i < body.size
          result << body[start...i]
        else
          start = i
          while i < body.size && ![' ', '\n', '\r', '\t', '(', '<'].includes?(body[i])
            i += 1
          end
          tok = body[start...i]
          if (val = tok.to_f?)
            result << val
          end
        end
      end
      result
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
    private def split_into_words(text : String, x : Float64, y : Float64, font_size : Float64, total_width : Float64, page_num : Int32, font_name : String) : Array(Word)
      result = [] of Word
      return result if text.strip.empty?

      # Per-char estimated advance (we don't have per-glyph widths
      # in this minimal implementation).
      char_w = text.size > 0 ? total_width / text.size : 0.0

      parts = text.split(' ')
      cursor = x
      parts.each_with_index do |part, idx|
        if idx > 0
          cursor += char_w # account for the space
        end
        next if part.empty?
        part_w = char_w * part.size
        bbox = Bbox.new(
          x_min: cursor,
          y_min: y,
          x_max: cursor + part_w,
          y_max: y + font_size,
        )
        result << Word.new(
          text: part,
          bbox: bbox,
          page: page_num,
          font_size: font_size,
          font_name: font_name,
        )
        cursor += part_w
      end
      result
    end
  end
end
