# frozen_string_literal: true

require 'json'

module ModuleTester
  module Metadata
    module_function

    def evaluate(module_dir, puppet_version)
      metadata_path = File.join(module_dir, 'metadata.json')
      return ['requires_manual_review', 'metadata.json not found'] unless File.exist?(metadata_path)

      payload = JSON.parse(File.read(metadata_path))
      requirements = payload.fetch('requirements', [])
      puppet_req = requirements.find { |r| r['name'] == 'puppet' }
      return ['unsupported_by_metadata', 'No Puppet requirement declared in metadata.json'] unless puppet_req

      expr = puppet_req['version_requirement'].to_s.strip
      return ['requires_manual_review', 'Puppet requirement has no version range'] if expr.empty?

      if satisfies_range?(puppet_version, expr)
        ['supported', "Puppet #{puppet_version} satisfies #{expr}"]
      else
        ['unsupported_by_metadata', "Puppet #{puppet_version} does not satisfy requirement #{expr}"]
      end
    rescue JSON::ParserError => e
      ['requires_manual_review', "metadata.json parse error: #{e.message}"]
    end

    def satisfies_range?(version, expression)
      v = parse_semver(version)
      return false if v.nil?

      if expression.end_with?('.x')
        prefix = expression[0..-3]
        return version.start_with?("#{prefix}.") || version == prefix
      end

      tokens = expression.split
      return false if tokens.length.odd?

      tokens.each_slice(2) do |op, expected_raw|
        expected = parse_semver(expected_raw)
        return false if expected.nil?

        cmp = compare_semver(v, expected)
        return false if op == '>' && cmp <= 0
        return false if op == '>=' && cmp < 0
        return false if op == '<' && cmp >= 0
        return false if op == '<=' && cmp > 0
        return false if op == '=' && cmp != 0
      end

      true
    end

    def parse_semver(raw)
      parts = raw.to_s.split('-').first.to_s.split('.')
      parts << '0' while parts.length < 3
      nums = parts.first(3).map { |p| Integer(p, exception: false) }
      return nil if nums.any?(&:nil?)

      nums
    end

    def compare_semver(left, right)
      return -1 if left < right
      return 1 if left > right

      0
    end
  end
end
