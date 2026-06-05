require "option_parser"
require "../pdf2text"

# pdf2html — convertit un PDF en HTML positionné (port Crystal de
# l'utilitaire `pdftohtml` de poppler-utils).
#
# S'appuie sur l'extracteur de texte positionné de `pdf2text` : chaque
# mot devient un `<span>` placé en absolu, reproduisant la mise en page
# (mode « complexe » de poppler). Sortie autonome en un seul fichier.
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short.

usage = <<-USAGE
  Usage : pdf2html <fichier.pdf> [<sortie.html>] [options]
          pdf2html help [<sous-commande>]
          pdf2html --version | -V

  Options :
    -o, --output FICHIER  Fichier HTML de sortie
    -f, --first N         Première page à convertir
    -l, --last N          Dernière page à convertir
    -s, --stdout          Écrire le HTML sur la sortie standard
    -t, --title TITRE     Titre du document (défaut : nom du fichier)
    -p, --password MDP    Mot de passe du document chiffré
    -V, --version         Affiche la version
    -h, --help            Affiche cette aide

  Convertit un PDF en HTML reproduisant la mise en page (un <div> par
  page, un <span> positionné par mot). La sortie par défaut est
  <fichier>.html. Lecture pure — le document source n'est pas modifié.
  USAGE

output : String? = nil
first_page : Int32? = nil
last_page : Int32? = nil
to_stdout = false
title : String? = nil
password = ""

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-o FICHIER", "--output FICHIER", "Output HTML file") { |v| output = v }
  op.on("-f N", "--first N", "First page") { |v| first_page = v.to_i? }
  op.on("-l N", "--last N", "Last page") { |v| last_page = v.to_i? }
  op.on("-s", "--stdout", "Write to stdout") { to_stdout = true }
  op.on("-t TITRE", "--title TITRE", "Document title") { |v| title = v }
  op.on("-p MDP", "--password MDP", "Document password") { |v| password = v }
  op.on("-V", "--version", "Show version") do
    puts "pdf2html #{Pdf2Text::VERSION}"
    exit 0
  end
  op.on("-h", "--help", "Show this help") do
    puts usage
    exit 0
  end
  op.invalid_option do |flag|
    STDERR.puts "Option inconnue : #{flag}"
    STDERR.puts usage
    exit 1
  end
end

positional = [] of String
parser.unknown_args { |args| positional = args }
parser.parse(ARGV)

# Convention ALOLI : `help [<sous-commande>]` positionnel.
if !positional.empty? && positional.first == "help"
  puts usage
  exit 0
end

if positional.empty?
  STDERR.puts "Erreur : aucun fichier PDF spécifié."
  STDERR.puts usage
  exit 1
end

input = positional[0]

unless File.exists?(input)
  STDERR.puts "Erreur : fichier introuvable : #{input}"
  exit 2
end

begin
  extract = Pdf2Text::Extractor.extract(input)
rescue ex : Pdf2Text::Extractor::ExtractError
  STDERR.puts "Erreur d'extraction : #{ex.message}"
  exit 3
end

# Filtrer la plage de pages demandée.
pages = extract.pages
if f = first_page
  pages = pages.select { |page| page.number >= f }
end
if l = last_page
  pages = pages.select { |page| page.number <= l }
end
filtered = Pdf2Text::Extract.new(source: extract.source, pages: pages)

html = Pdf2Text::Html.render(filtered, title)

if to_stdout
  print html
  exit 0
end

out_opt = output
positional_out = positional[1]?
dest = out_opt || positional_out || begin
  ext = File.extname(input)
  base = input[0, input.size - ext.size]
  "#{base}.html"
end

File.write(dest, html)
puts "HTML écrit → #{dest} (#{filtered.pages.size} page(s), #{filtered.total_words} mots)"
