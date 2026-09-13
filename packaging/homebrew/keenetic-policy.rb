class KeeneticPolicy < Formula
  desc "Manage Keenetic client policies, Internet blocks, and Wake-on-LAN"
  homepage "https://github.com/osteotek/omarchy-keenetic"
  url "https://github.com/osteotek/omarchy-keenetic/releases/download/v1.1.0/keenetic-policy-1.1.0.tar.gz"
  sha256 "fa0f657b808b49f7ae09b00e06ed6e6ea9b82f2a0fcc7485d38366a3dd79d73f"
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
