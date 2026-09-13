class KeeneticPolicy < Formula
  desc "Manage Keenetic client policies, Internet blocks, and Wake-on-LAN"
  homepage "https://github.com/osteotek/omarchy-keenetic"
  url "https://github.com/osteotek/omarchy-keenetic/releases/download/v1.1.1/keenetic-policy-1.1.1.tar.gz"
  sha256 "ada3e52cf22d4e1626208538e3f5aeefa305877bd2db1a9bb46eba32c146d285"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic-policy.sh" => "keenetic-policy"
    bash_completion.install "completions/keenetic-policy.bash" => "keenetic-policy"
  end

  test do
    assert_match "keenetic-policy 1.1.1", shell_output("#{bin}/keenetic-policy --version")
  end
end
