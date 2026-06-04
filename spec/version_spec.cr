require "./spec_helper"
require "yaml"

# Garde-fou contre la désynchronisation entre la constante
# `Pdf2Text::VERSION` (lue au compile-time depuis `shard.yml`) et
# la valeur réelle du `version:` du shard.yml.
#
# Si jamais on régresse sur le macro `read_file` dans
# `src/pdf2text/version.cr`, ce spec rouge alerte immédiatement.
#
# Cf. note mémoire `feedback_shard_version_macro.md`.
describe Pdf2Text do
  it "VERSION matche shard.yml (compile-time read, pas de désynchro)" do
    yml = YAML.parse(File.read(File.join(__DIR__, "..", "shard.yml")))
    Pdf2Text::VERSION.should eq(yml["version"].as_s)
  end

  it "VERSION est au format SemVer X.Y.Z (création) ou X.Y.Z.N (portage)" do
    Pdf2Text::VERSION.should match(/^\d+\.\d+\.\d+(\.\d+)?$/)
  end
end
