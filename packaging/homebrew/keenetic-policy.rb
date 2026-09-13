class KeeneticPolicy < Formula
  desc "Manage Keenetic client policies, Internet blocks, and Wake-on-LAN"
  homepage "https://github.com/osteotek/omarchy-keenetic"
  url "https://github.com/osteotek/omarchy-keenetic/releases/download/v1.1.0/keenetic-policy-1.1.0.tar.gz"
  sha256 "c80054569f5d58682c1caba3e15776a66f59ae71ce0e46f1a97a0e4a404e458e"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic-policy.sh" => "keenetic-policy"
    bash_completion.install "completions/keenetic-policy.bash" => "keenetic-policy"
  end

  test do
    assert_match "keenetic-policy 1.1.0", shell_output("#{bin}/keenetic-policy --version")
  end
end
