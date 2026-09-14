class KeeneticPolicy < Formula
  desc "Manage Keenetic client policies, Internet blocks, and Wake-on-LAN"
  homepage "https://github.com/osteotek/keenetic-policy"
  url "https://github.com/osteotek/keenetic-policy/releases/download/v1.1.2/keenetic-policy-1.1.2.tar.gz"
  sha256 "05c886cd0700676e4ce1b9aad7b6f07eae2c9ec3b8a4eba3567e55dfda1e4f90"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "fzf" => :optional

  def install
    bin.install "keenetic-policy.sh" => "keenetic-policy"
    bash_completion.install "completions/keenetic-policy.bash" => "keenetic-policy"
  end

  test do
    assert_match "keenetic-policy 1.1.2", shell_output("#{bin}/keenetic-policy --version")
  end
end
