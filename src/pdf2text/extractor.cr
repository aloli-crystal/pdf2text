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

    private def decode_stream(obj_body : Bytes) : String
      s = String.new(obj_body)
      start = s.index("stream")
      finish = s.index("endstream")
      return "" unless start && finish
      # Skip "stream\n" or "stream\r\n"
      data_start = start + "stream".size
      while data_start < s.size && (s[data_start] == '\n' || s[data_start] == '\r')
        data_start += 1
      end
      raw = obj_body[data_start, finish - data_start - 1]?
      return "" unless raw

      if s.includes?("/FlateDecode")
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

    private record FontInfo,
      key : String,
      name : String,
      avg_advance : Float64 # average glyph advance in unscaled units

    private def build_font_map(objects : ObjectMap, page_s : String) : Hash(String, FontInfo)
      result = Hash(String, FontInfo).new
      resources_ref = extract_ref(page_s, "/Resources")
      resources_s = if resources_ref && (r = objects[resources_ref]?)
                      String.new(r)
                    else
                      # /Resources can also be an inline dict on the page
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
          name = if (mn = font_s.match(/\/BaseFont\s*\/(\S+)/))
                   mn[1]
                 else
                   "unknown"
                 end
          # Crude advance estimate : we'll use 500 units (= half em)
          # which is roughly right for sans fonts at 1000-unit space.
          result[key] = FontInfo.new(key: key, name: name, avg_advance: 500.0)
        end
      end
      result
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
          # operand : (text)
          if (str = operands.last?) && in_text
            text = decode_string(str)
            unless text.empty?
              w = estimate_width(text, font_size, fonts[font_key]?)
              words.concat split_into_words(text, tx, ty, font_size, w, page_num, fonts[font_key]?.try(&.name) || "?")
              tx += w
            end
          end
          operands.clear
        when "TJ"
          # operand : [ (text) num (text) num ... ]
          if (arr = operands.last?) && in_text
            elts = parse_tj_array(arr)
            elts.each do |elt|
              case elt
              when String
                text = decode_string(elt)
                unless text.empty?
                  w = estimate_width(text, font_size, fonts[font_key]?)
                  words.concat split_into_words(text, tx, ty, font_size, w, page_num, fonts[font_key]?.try(&.name) || "?")
                  tx += w
                end
              when Float64
                # Negative number = advance to the right by -elt * font_size / 1000
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
    private def decode_string(s : String) : String
      return "" unless s.starts_with?('(') && s.ends_with?(')')
      body = s[1..-2]
      String.build do |io|
        i = 0
        while i < body.size
          c = body[i]
          if c == '\\' && i + 1 < body.size
            nc = body[i + 1]
            case nc
            when 'n' then io << '\n'; i += 2
            when 'r' then io << '\r'; i += 2
            when 't' then io << '\t'; i += 2
            when 'b' then io << '\b'; i += 2
            when 'f' then io << '\f'; i += 2
            when '(' then io << '('; i += 2
            when ')' then io << ')'; i += 2
            when '\\' then io << '\\'; i += 2
            when '0'..'7'
              # Octal escape \nnn
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
        else
          start = i
          while i < body.size && ![' ', '\n', '\r', '\t', '('].includes?(body[i])
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

    # Approximate the rendered width of a text in PDF points.
    # Uses the font's `avg_advance` × char count × font_size / 1000
    # (PDF convention : font units are 1/1000 of em).
    private def estimate_width(text : String, font_size : Float64, font : FontInfo?) : Float64
      advance = font.try(&.avg_advance) || 500.0
      text.size * advance * font_size / 1000.0
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
