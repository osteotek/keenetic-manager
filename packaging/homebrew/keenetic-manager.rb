class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.4.0/keenetic-manager-1.4.0.tar.gz"
  sha256 "2e7a78c40ab27f44e1e1cbe31f196d0ecf9620d60209fd96b6ec94bfd93787fb"
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
    assert_match "keenetic 1.4.0", shell_output("#{bin}/keenetic --version")
  end
end
