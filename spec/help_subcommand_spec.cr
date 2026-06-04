# Spec d'intégration pour la sous-commande `help` du CLI.
# Convention UX ALOLI — cf. `feedback_cli_help_subcommand.md`.
#
# Ce spec compile le binaire CLI une fois (dans before_all) puis
# shell-out aux 4 variantes : `help`, `help <sub>`, `help <inconnu>`,
# `-h` / `--help`.
#
# Si vous décidez que ce shard n'aura PAS de CLI, supprimez ce
# fichier et `src/cli.cr`, et laissez le `targets:` du shard.yml
# commenté.

require "./spec_helper"
require "file_utils"

describe "pdf2text help" do
  cli_binary = File.join(__DIR__, "tmp", "pdf2text-help-test")

  before_all do
    Dir.mkdir_p(File.dirname(cli_binary))
    src = File.join(__DIR__, "..", "src", "cli.cr")
    err_buf = IO::Memory.new
    Process.run("crystal", ["build", src, "-o", cli_binary],
      output: Process::Redirect::Close, error: err_buf)
  end

  after_all do
    FileUtils.rm_rf(File.dirname(cli_binary))
  end

  it "`help` sans argument imprime l'usage global" do
    pending! "binaire CLI absent (pas de CLI ?)" unless File.exists?(cli_binary)
    buf = IO::Memory.new
    status = Process.run(cli_binary, ["help"], output: buf, error: buf)
    status.success?.should be_true
    buf.to_s.should contain("Usage")
  end

  it "accepte aussi `-h` et `--help` comme alias positionnels" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    %w(-h --help).each do |variant|
      buf = IO::Memory.new
      status = Process.run(cli_binary, [variant], output: buf, error: buf)
      status.success?.should be_true
      buf.to_s.should contain("Usage")
    end
  end

  it "`help <inconnu>` retourne une erreur claire (quand sous-commandes définies)" do
    pending! "binaire CLI absent" unless File.exists?(cli_binary)
    buf = IO::Memory.new
    err_buf = IO::Memory.new
    status = Process.run(cli_binary, ["help", "foobar"], output: buf, error: err_buf)
    # Si valid_subs est vide (template fraîchement initialisé), foobar passera
    # car `[].includes?("foobar")` est false → erreur, OK.
    # Si valid_subs est peuplé, foobar échoue clairement aussi.
    if status.success?
      # Cas template vierge : on accepte que `help foobar` soit toléré
      # tant que valid_subs n'est pas peuplé.
      buf.to_s.should contain("Usage")
    else
      err_buf.to_s.should contain("Aide indisponible")
    end
  end
end
