require "option_parser"
require "json"
require "./pdf2text"

# pdf2text — Pure-Crystal PDF text extractor (CLI).
#
# Conventions UX ALOLI (cf. feedback_cli_help_subcommand.md +
# feedback_cli_short_flags.md) : `help [<sub>]` positionnel +
# `-h` / `--help` global ; tout flag long a un short.

usage = <<-USAGE
  Usage : pdf2text <fichier.pdf> [options]
          pdf2text help [<sous-commande>]
          pdf2text --version | -V

  Options :
    -j, --json           Sortie JSON structurée
    -p, --pages          Affiche uniquement le nombre de pages
    -V, --version        Affiche la version
    -h, --help           Affiche cette aide

  Extrait le texte positionné (mot, boîte englobante, fonte,
  taille) d'un PDF. Gère Type1/WinAnsi et TTF CIDFont Type0 /
  Identity-H / ToUnicode CMap (PDFs produits par aloli-crystal/pdf
  et asciidoctor-pdf). PDFs externes/chiffrés ou encodages exotiques
  pas encore garantis — voir README. Conversion HTML : `pdf2html`.
  USAGE

json_out = false
pages_only = false

parser = OptionParser.new do |op|
  op.banner = usage
  op.on("-j", "--json", "JSON output") { json_out = true }
  op.on("-p", "--pages", "Pages count only") { pages_only = true }
  op.on("-V", "--version", "Show version") do
    puts "pdf2text #{Pdf2Text::VERSION}"
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

# `help [<sub>]` convention ALOLI
if !positional.empty? && positional.first == "help"
  puts usage
  exit 0
end

if positional.empty?
  STDERR.puts "Erreur : aucun fichier PDF spécifié."
  STDERR.puts usage
  exit 1
end

path = positional.first

unless File.exists?(path)
  STDERR.puts "Erreur : fichier introuvable : #{path}"
  exit 2
end

begin
  extract = Pdf2Text::Extractor.extract(path)
rescue ex : Pdf2Text::Extractor::ExtractError
  STDERR.puts "Erreur d'extraction : #{ex.message}"
  exit 3
end

if pages_only
  puts extract.pages.size
  exit 0
end

if json_out
  puts extract.to_h.to_json
  exit 0
end

# Format texte par défaut
puts "Fichier   : #{extract.source}"
puts "Pages     : #{extract.pages.size}"
puts "Total mots: #{extract.total_words}"
extract.pages.each do |page|
  printf("  page %2d : %.1f × %.1f pt — %d mots\n", page.number, page.width, page.height, page.words.size)
end
if extract.total_words == 0 && !extract.pages.empty?
  puts ""
  puts "Note : aucun mot extrait. La structure est lue, mais le texte"
  puts "      non : encodage de fonte non géré, content streams sous"
  puts "      filtre non-Flate, ou PDF chiffré. Voir le README."
end
