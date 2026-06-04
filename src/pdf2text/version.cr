module Pdf2Text
  # Lue au compile-time depuis `shard.yml` via le macro `read_file`.
  # Évite la désynchronisation entre la constante Crystal et le
  # `version:` du shard.yml (cas vécu en mai 2026 avec
  # crystal-combine-pdf : 7 versions inscrivaient la mauvaise valeur
  # dans le `/Producer` des PDFs générés).
  #
  # Cf. note mémoire ALOLI `feedback_shard_version_macro.md`.
  VERSION = {{
              (read_file("#{__DIR__}/../../shard.yml")
                .lines
                .find(&.starts_with?("version:")) || "version: 0.0.0")
                .gsub(/^version:\s*/, "")
                .chomp
            }}
end
