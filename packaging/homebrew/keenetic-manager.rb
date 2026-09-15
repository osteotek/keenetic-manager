class KeeneticManager < Formula
  desc "Inspect Keenetic routers and manage client policies"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.2.0/keenetic-manager-1.2.0.tar.gz"
  sha256 "731d3daa1e89cd9caa4face156d6dcd429d7b7ceb9ef864520d0d112aa2d2915"
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
