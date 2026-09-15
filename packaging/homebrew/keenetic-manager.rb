class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.2.0/keenetic-manager-1.2.0.tar.gz"
  sha256 "8b35bfb959b4e2773b0b048beff248cba1a6a1ca655cf6ea4f3063e97da6ed37"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic" => "keenetic"
    bash_completion.install "completions/keenetic.bash" => "keenetic"
  end

  test do
    assert_match "keenetic 1.2.0", shell_output("#{bin}/keenetic --version")
  end
end
