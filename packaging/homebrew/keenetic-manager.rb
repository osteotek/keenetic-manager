class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.3.0/keenetic-manager-1.3.0.tar.gz"
  sha256 "995bd559270737b150d6703079817a74a5e8e8a2cbc092511c6eca3db15b714a"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic" => "keenetic"
    bash_completion.install "completions/keenetic.bash" => "keenetic"
  end

  test do
    assert_match "keenetic 1.3.0", shell_output("#{bin}/keenetic --version")
  end
end
