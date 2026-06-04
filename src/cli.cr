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

  Périmètre v#{Pdf2Text::VERSION} (alpha) — voir README pour la
  roadmap complète. Cible les PDFs produits par
  aloli-crystal/pdf (Type1 WinAnsi, TTF CIDFont/Identity-H).
  L'extraction texte est une ébauche : structure de pages et
  dimensions OK, parsing des content streams en chantier.
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
extract.pages.each do |p|
  printf("  page %2d : %.1f × %.1f pt — %d mots\n", p.number, p.width, p.height, p.words.size)
end
if extract.total_words == 0 && !extract.pages.empty?
  puts ""
  puts "Note : aucun mot extrait. C'est attendu en v#{Pdf2Text::VERSION}"
  puts "      pour la plupart des PDFs — le parsing des content"
  puts "      streams est encore une ébauche. Voir le README pour"
  puts "      la roadmap v0.2.0+ (décodage WinAnsi, ToUnicode CMap,"
  puts "      bbox précise via font /Widths)."
end
