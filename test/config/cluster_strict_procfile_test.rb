# frozen_string_literal: true

require "test_helper"
require "shellwords"

class ClusterStrictProcfileTest < ActiveSupport::TestCase
  test "declares one isolated low-priority Cluster strict consumer" do
    lines = File.readlines(Rails.root.join("Procfile.dev"), chomp: true)
    declarations = lines.grep(/\Asidekiq_cluster_strict:/)

    assert_equal 1, declarations.size
    line = declarations.sole
    command = line.split(":", 2).last.strip
    words = Shellwords.split(command)

    assert_includes words.each_cons(2).to_a, ["-c", "1"]
    assert_includes words.each_cons(2).to_a, ["-q", "cluster_strict"]
    assert_equal ["cluster_strict"], words.each_cons(2).filter_map { |a, b| b if a == "-q" }
    assert_includes words.each_cons(3).to_a, ["nice", "-n", "15"]
    assert_match(/bundle exec sidekiq/, command)
    assert_no_match(/scheduler|perform|runner|rails/, command)
  end
end
