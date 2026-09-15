class KeeneticManager < Formula
  desc "Manage Keenetic client policies, Internet blocks, and Wake-on-LAN"
  homepage "https://github.com/osteotek/keenetic-manager"
  url "https://github.com/osteotek/keenetic-manager/releases/download/v1.1.3/keenetic-manager-1.1.3.tar.gz"
  sha256 "2d5c57a9b8d9f85ac1ec6eb5d99d23bb3d8524774c7c166b9e071d48f356559c"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic" => "keenetic"
    bash_completion.install "completions/keenetic.bash" => "keenetic"
  end

  test do
    assert_match "keenetic 1.1.3", shell_output("#{bin}/keenetic --version")
  end
end
