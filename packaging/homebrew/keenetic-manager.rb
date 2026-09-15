class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.3.1/keenetic-manager-1.3.1.tar.gz"
  sha256 "f914cbfe780451905213145db2936a7db9226c96b7499af0b5fd60e2313ac34b"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic" => "keenetic"
    bash_completion.install "completions/keenetic.bash" => "keenetic"
    zsh_completion.install "completions/_keenetic"
  end

  test do
    assert_match "keenetic 1.3.1", shell_output("#{bin}/keenetic --version")
  end
end
