# frozen_string_literal: true

module ModuleTester
  # Deterministic fact-provider detector.
  #
  # Runs after `bundle install` and before unit tests. Answers the question
  # "When module test code calls `require 'facter'`, which gem actually
  # provides Facter — facter (Perforce/upstream) or openfact (OpenVox)?"
  #
  # Detection combines two signals, both cheap and reliable:
  #   1. A one-shot `bundle exec ruby -e "require 'facter'; ..."` that prints
  #      the source_location of `Facter.value`. Whichever gem path wins
  #      `require 'facter'` in this resolved bundle is what test child
  #      processes will see.
  #   2. Parsing `Gemfile.lock` to enumerate which fact / puppet provider
  #      gems were resolved (and at what version).
  #
  # Unlike a runtime hook on Facter, this approach does not depend on tests
  # actually exercising the Facter API, does not depend on env-var inheritance
  # across `system()`-spawned child processes, and is not defeated by
  # rspec-puppet's `facter_implementation = 'rspec'` stub layer.
  module FactProviderDetector
    module_function

    PROBE_RUBY = <<~RUBY
      begin
        require 'facter'
        loc = Facter.method(:value).source_location
        path = loc ? loc.first : ''
        puts "FACT_PROVIDER_SOURCE=" + path.to_s
        puts "FACT_PROVIDER_VERSION=" + (defined?(Facter::VERSION) ? Facter::VERSION.to_s : '')
      rescue LoadError => e
        puts "FACT_PROVIDER_SOURCE="
        puts "FACT_PROVIDER_LOAD_ERROR=" + e.message
      end
    RUBY

    # Build the StageResult for the fact_provider stage and return it. Also
    # mutates the result hash to add an OpenFact warning when applicable.
    #
    # Options:
    #   enforcement: nil | 'skipped' | 'attempted' | 'succeeded' | 'failed'
    def detect(stage_runner, module_dir, env, result, enforcement: nil)
      lockfile_path = resolve_lockfile_path(module_dir, env)
      lock_info = parse_gemfile_lock(lockfile_path)
      probe_info = run_resolution_probe(stage_runner, module_dir, env)

      provider, provider_gem = classify_provider(probe_info, lock_info)

      summary = build_summary(provider, provider_gem, probe_info, lock_info, lockfile_path,
                              enforcement: enforcement)

      stage = StageResult.new(
        name: 'fact_provider',
        status: 'passed',
        command: probe_info[:command_display],
        exit_code: probe_info[:exit_code] || 0,
        duration_seconds: probe_info[:duration_seconds] || 0,
        output: summary
      )

      maybe_emit_openfact_warning(provider, lock_info, result, enforcement: enforcement)

      stage
    end

    def resolve_lockfile_path(module_dir, env)
      candidates = []

      bundle_gemfile = env.fetch('BUNDLE_GEMFILE', '').to_s.strip
      unless bundle_gemfile.empty?
        gemfile_path = if File.absolute_path(bundle_gemfile) == bundle_gemfile
                         bundle_gemfile
                       else
                         File.expand_path(bundle_gemfile, module_dir)
                       end
        candidates << "#{gemfile_path}.lock"
      end

      candidates << File.join(module_dir, 'Gemfile.lock')
      candidates << File.join(module_dir, 'Gemfile.puppetcore.lock')

      candidates.find { |path| File.exist?(path) } || candidates.first
    end

    def parse_gemfile_lock(path)
      info = { facter: nil, openfact: nil, puppet: nil, openvox: nil, available: false }
      return info unless File.exist?(path)

      info[:available] = true
      File.foreach(path) do |line|
        # GEMS section entries look like:  "    facter (4.17.0)"
        m = line.match(/^\s{4}([a-z0-9_\-]+)\s\(([^)]+)\)\s*$/)
        next unless m

        name = m[1]
        version = m[2]
        case name
        when 'facter' then info[:facter] ||= version
        when 'openfact' then info[:openfact] ||= version
        when 'puppet' then info[:puppet] ||= version
        when 'openvox' then info[:openvox] ||= version
        end
      end
      info
    rescue StandardError
      info
    end

    def run_resolution_probe(stage_runner, module_dir, env)
      command = ['bundle', 'exec', 'ruby', '-e', PROBE_RUBY]

      unless stage_runner.command_available?('bundle')
        return {
          source: '',
          version: '',
          load_error: 'bundle command not available',
          exit_code: nil,
          duration_seconds: 0,
          command_display: nil
        }
      end

      stage = stage_runner.run_stage('fact_provider_probe', command, module_dir, env)

      source = ''
      version = ''
      load_error = nil
      stage.output.to_s.each_line do |line|
        case line
        when /^FACT_PROVIDER_SOURCE=(.*)$/ then source = Regexp.last_match(1).strip
        when /^FACT_PROVIDER_VERSION=(.*)$/ then version = Regexp.last_match(1).strip
        when /^FACT_PROVIDER_LOAD_ERROR=(.*)$/ then load_error = Regexp.last_match(1).strip
        end
      end

      {
        source: source,
        version: version,
        load_error: load_error,
        exit_code: stage.exit_code,
        duration_seconds: stage.duration_seconds,
        command_display: stage.command
      }
    end

    def classify_provider(probe_info, lock_info)
      source = probe_info[:source].to_s

      if source.include?('/gems/openfact-')
        return ['openfact', "openfact@#{lock_info[:openfact] || extract_version_from_path(source)}"]
      end
      if source.include?('/gems/facter-')
        return ['facter', "facter@#{lock_info[:facter] || extract_version_from_path(source)}"]
      end

      # Probe failed to resolve — fall back to lockfile inference.
      if lock_info[:openfact] && !lock_info[:facter]
        return ['openfact', "openfact@#{lock_info[:openfact]}"]
      end
      if lock_info[:facter] && !lock_info[:openfact]
        return ['facter', "facter@#{lock_info[:facter]}"]
      end

      ['unknown', '']
    end

    def extract_version_from_path(path)
      m = path.match(%r{/gems/(?:facter|openfact)-([^/]+)/})
      m ? m[1] : ''
    end

    def build_summary(provider, provider_gem, probe_info, lock_info, lockfile_path,
              enforcement: nil)
      puppet_provider = if lock_info[:puppet] && lock_info[:openvox]
                          "puppet@#{lock_info[:puppet]}+openvox@#{lock_info[:openvox]}"
                        elsif lock_info[:puppet]
                          "puppet@#{lock_info[:puppet]}"
                        elsif lock_info[:openvox]
                          "openvox@#{lock_info[:openvox]}"
                        else
                          'unknown'
                        end

      detection_method = if provider != 'unknown' && probe_info[:source].to_s.include?('/gems/')
                           'bundle_resolution'
                         elsif lock_info[:available]
                           'gemfile_lock_inference'
                         else
                           'unknown'
                         end

      parts = [
        "fact_provider=#{provider}",
        "fact_provider_gem=#{provider_gem.empty? ? 'unknown' : provider_gem}",
        "puppet_provider=#{puppet_provider}",
        "gemfile_facter=#{lock_info[:facter] || 'absent'}",
        "gemfile_openfact=#{lock_info[:openfact] || 'absent'}",
        "gemfile_lock=#{File.basename(lockfile_path)}",
        "detection_method=#{detection_method}",
        "facter_runtime_version=#{probe_info[:version].to_s.empty? ? 'unknown' : probe_info[:version]}"
      ]
      parts << "load_error=#{probe_info[:load_error]}" if probe_info[:load_error]
      parts << "enforcement=#{enforcement}" if enforcement
      parts.join(' ')
    end

    def maybe_emit_openfact_warning(provider, lock_info, result, enforcement: nil)
      # If RUBYOPT enforcement succeeded the probe will report facter, not
      # openfact, so neither condition below fires.  But as an extra guard:
      # skip the warning entirely when enforcement explicitly succeeded.
      return if enforcement == 'succeeded'

      openfact_active = provider == 'openfact'
      openfact_only_in_lock = !openfact_active && lock_info[:openfact] && !lock_info[:facter]

      return unless openfact_active || openfact_only_in_lock

      warning = if openfact_active
                  'Compatibility signal: `require "facter"` resolves to the OpenFact gem in this bundle. ' \
                    'This run is not a definitive Perforce Puppet Core + Perforce Facter compatibility test.'
                else
                  'Compatibility signal: only the OpenFact gem is present in Gemfile.lock (no `facter` gem). ' \
                    'This run is not a definitive Perforce Puppet Core + Perforce Facter compatibility test.'
                end

      result[:dependency_status] = 'warning'
      existing = result[:dependency_message].to_s.strip
      result[:dependency_message] = if existing.empty? || existing.include?(warning)
                                      warning
                                    else
                                      "#{existing}\n#{warning}"
                                    end
      Annotations.github_annotation('warning', "#{result[:module]} fact provider", warning)
    end
  end
end
