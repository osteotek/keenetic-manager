class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.2.0/keenetic-manager-1.2.0.tar.gz"
  sha256 "a5f1182fa96a1fe819d8984faa59d762bb0acdde6c8114937ba67934e928dfb9"
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
