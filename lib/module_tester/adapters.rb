# frozen_string_literal: true

require 'json'
require 'fileutils'

module ModuleTester
  class Adapters
    def initialize(stage_runner, docker, options)
      @stage = stage_runner
      @docker = docker
      @options = options
    end

    def run(module_dir, env, profile, result)
      if @options[:test_mode] == 'acceptance'
        run_acceptance(module_dir, env, result, profile)
        return
      end

      run_unit(module_dir, env, profile, result)
    end

    private

    def run_unit(module_dir, env, profile, result)
      prefer_rake = result[:capability].is_a?(Hash) && result[:capability]['uses_vox_vars']

      if @stage.command_available?('pdk') && !prefer_rake
        validate_stage = @stage.run_stage('validate', ['pdk', 'validate', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
        unit_stage = @stage.run_stage('unit', ['pdk', 'test', 'unit', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        result[:stages] << unit_stage
        result[:stages] << StageResult.new(
          name: 'fact_runtime_probe',
          status: 'passed',
          command: nil,
          exit_code: 0,
          duration_seconds: 0,
          output: 'Fact runtime probe is not applied to the PDK adapter path.'
        )
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
        return
      end

      return unless File.exist?(File.join(module_dir, 'Rakefile')) && @stage.command_available?('bundle')

      tasks = @stage.rake_tasks(module_dir, env)
      if tasks.include?('validate')
        validate_stage = @stage.run_stage('validate', ['bundle', 'exec', 'rake', 'validate'], module_dir, env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
      end

      if tasks.include?('spec')
        unit_env = build_fact_probe_env(module_dir, env)
        unit_stage = @stage.run_stage('unit', probe_wrapped_rake_command('spec'), module_dir, unit_env)
        result[:stages] << unit_stage
        annotate_fact_runtime_provider(module_dir, result)
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      elsif tasks.include?('test')
        unit_env = build_fact_probe_env(module_dir, env)
        unit_stage = @stage.run_stage('unit', probe_wrapped_rake_command('test'), module_dir, unit_env)
        result[:stages] << unit_stage
        annotate_fact_runtime_provider(module_dir, result)
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      end
    end

    def build_fact_probe_env(module_dir, env)
      probe_dir = File.join(module_dir, '.fact-runtime-probe')

      FileUtils.rm_rf(probe_dir)
      FileUtils.mkdir_p(probe_dir)

      probe_env = env.dup
      probe_env['PUPPET_FACT_RUNTIME_PROBE_ENABLED'] = 'true'
      probe_env['PUPPET_FACT_RUNTIME_PROBE_OUTPUT_DIR'] = probe_dir

      probe_path = File.expand_path('fact_runtime_probe.rb', __dir__)
      existing_rubyopt = probe_env['RUBYOPT'].to_s.strip
      probe_env['RUBYOPT'] = [existing_rubyopt, "-r#{probe_path}"].reject(&:empty?).join(' ')
      probe_env
    end

    def probe_wrapped_rake_command(task_name)
      probe_path = File.expand_path('fact_runtime_probe.rb', __dir__)
      ['bundle', 'exec', 'ruby', "-r#{probe_path}", '-S', 'rake', task_name]
    end

    def annotate_fact_runtime_provider(module_dir, result)
      probe_dir = File.join(module_dir, '.fact-runtime-probe')
      probe_files = Dir.glob(File.join(probe_dir, 'probe-*.kv')).sort

      if probe_files.empty?
        result[:stages] << StageResult.new(
          name: 'fact_runtime_probe',
          status: 'passed',
          command: nil,
          exit_code: 0,
          duration_seconds: 0,
          output: 'probe_capture=failed probe_files=0 hooks_installed_any=false runtime_fact_api_used_any=false call_count_total=0 providers_seen= facts_source_hint=unknown'
        )
        return
      end

      payloads = probe_files.map { |path| parse_probe_payload(File.read(path)) }
      used_runtime_fact_api = payloads.any? { |payload| payload['runtime_fact_api_used'] == true }
      providers_seen = payloads.flat_map { |payload| Array(payload['providers_seen']) }.map(&:to_s).uniq.sort
      call_count = payloads.sum { |payload| payload['call_count'].to_i }
      hooks_installed = payloads.any? { |payload| payload['hooks_installed'] == true }

      unit_output = result[:stages].find { |stage| stage.name == 'unit' }&.output.to_s
      facterdb_signal = unit_output.match?(/FacterDB/i)

      source_hint = if used_runtime_fact_api
                      'runtime_fact_api'
                    elsif facterdb_signal
                      'facterdb_or_mocked_facts'
                    else
                      'no_runtime_fact_api_observed'
                    end

      summary = [
        'probe_capture=ok',
        "probe_files=#{probe_files.length}",
        "hooks_installed_any=#{hooks_installed}",
        "runtime_fact_api_used_any=#{used_runtime_fact_api}",
        "call_count_total=#{call_count}",
        "providers_seen=#{providers_seen.join(',')}",
        "facts_source_hint=#{source_hint}"
      ].join(' ')

      result[:stages] << StageResult.new(
        name: 'fact_runtime_probe',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: summary
      )

      return unless used_runtime_fact_api
      return unless providers_seen.include?('openfact')

      warning = 'Compatibility signal: unit tests resolved runtime facts through OpenFact. This run is not a definitive Perforce Puppet Core + Perforce Facter compatibility test.'

      result[:dependency_status] = 'warning'
      existing_message = result[:dependency_message].to_s.strip
      result[:dependency_message] = if existing_message.empty? || existing_message.include?(warning)
                                     warning
                                   else
                                     "#{existing_message}\n#{warning}"
                                   end
      Annotations.github_annotation('warning', "#{result[:module]} runtime fact provider", warning)
      result[:stages] << StageResult.new(
        name: 'openfact_runtime_warning',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: warning
      )
    rescue StandardError => e
      result[:stages] << StageResult.new(
        name: 'fact_runtime_probe',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: "Fact runtime probe diagnostics unavailable: #{e.message}"
      )
    end

    def parse_probe_payload(raw)
      text = raw.to_s
      stripped = text.lstrip
      if stripped.start_with?('{')
        parsed = JSON.parse(text)
        parsed['providers_seen'] = Array(parsed['providers_seen'])
        return parsed
      end

      data = {}
      text.each_line do |line|
        key, value = line.strip.split('=', 2)
        next if key.to_s.empty?

        data[key] = value.to_s
      end

      {
        'runtime_fact_api_used' => data['runtime_fact_api_used'] == 'true',
        'call_count' => Integer(data.fetch('call_count', '0'), exception: false) || 0,
        'providers_seen' => data.fetch('providers_seen', '').split(',').map(&:strip).reject(&:empty?),
        'hooks_installed' => data['hooks_installed'] == 'true',
        'errors_count' => Integer(data.fetch('errors_count', '0'), exception: false) || 0
      }
    end

    def run_acceptance(module_dir, env, result, profile)
      return unless @options[:allow_acceptance]
      return unless File.exist?(File.join(module_dir, 'Rakefile')) && @stage.command_available?('bundle')

      tasks = @stage.rake_tasks(module_dir, env)
      return unless result[:capability]['has_acceptance']
      return unless tasks.include?('beaker')

      puppet_core_api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').strip
      docker_mode = @options.fetch(:docker_mode, 'sshd')

      acceptance_env = env.dup
      acceptance_env['BEAKER_HYPERVISOR'] = 'docker'
      effective_setfile = nil
      effective_collection = nil

      if @options[:beaker_setfile] && !puppet_core_api_key.empty?
        # Stage 1: Build a Docker image with Puppet Core pre-installed.
        # The API key is used only during the build and is NOT passed to
        # the acceptance test environment, so untrusted module test code
        # cannot read it.
        image_tag, build_stage = @docker.build_puppet_core_image(
          @options[:beaker_setfile],
          profile.fetch('puppet_major'),
          puppet_core_api_key,
          docker_mode: docker_mode
        )
        result[:stages] << build_stage
        return if build_stage.status != 'passed'

        # Stage 2: Write a clean setfile that references the pre-built
        # image — no secrets embedded anywhere.
        effective_setfile = @docker.write_clean_setfile(@options[:beaker_setfile], image_tag, docker_mode: docker_mode)
        acceptance_env['BEAKER_SETFILE'] = effective_setfile
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = 'preinstalled'
        effective_collection = 'preinstalled'
      elsif @options[:beaker_setfile]
        # No API key — fall back to FOSS puppet from public yum.puppet.com
        effective_setfile = File.expand_path(@options[:beaker_setfile])
        effective_collection = "puppet#{profile.fetch('puppet_major')}"
        acceptance_env['BEAKER_SETFILE'] = effective_setfile
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = effective_collection
      else
        effective_collection = "puppet#{profile.fetch('puppet_major')}"
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = effective_collection
      end

      # Strip all secrets from the env before running untrusted test code.
      Docker.strip_secrets_from_env!(acceptance_env)

      diag_lines = []
      diag_lines << "BEAKER_SETFILE=#{effective_setfile}" if effective_setfile
      diag_lines << "BEAKER_PUPPET_COLLECTION=#{effective_collection}" if effective_collection
      diag_lines << "BEAKER_HYPERVISOR=#{acceptance_env['BEAKER_HYPERVISOR']}"
      if effective_setfile && File.exist?(effective_setfile)
        diag_lines << "--- Effective setfile content ---"
        diag_lines << File.read(effective_setfile)
      end
      result[:stages] << StageResult.new(
        name: 'acceptance_env',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: diag_lines.join("\n")
      )

      result[:stages] << @stage.run_stage('acceptance', ['bundle', 'exec', 'rake', 'beaker'], module_dir, acceptance_env)
    end

    def downgrade_puppet_server_default_unit_failure(result, unit_stage)
      return if unit_stage.nil?
      return if unit_stage.status == 'passed'

      output = unit_stage.output.to_s

      # Detect the specific Puppet 8.12 breaking change: the default value of the
      # 'server' setting changed from 'puppet' to '' (empty string).
      # Unit specs that hardcode the old default produce exactly this diff pattern.
      # See: https://help.puppet.com/core/current/Content/PuppetCore/PuppetReleaseNotes/release_notes_puppet_x-8-12-0.htm
      return unless output.include?('"server"=>"puppet"') && output.include?('"server"=>""')

      # Only downgrade when this is the sole rspec failure — don't mask unrelated failures.
      return if output.scan(/::error /).count > 1

      warning = 'Unit spec asserts the Puppet "server" setting default is "puppet", but Puppet Core 8.12+ ' \
                'changed this default to "" (empty string). The spec must be updated to reflect the ' \
                'new Puppet 8.12 behaviour. ' \
                'See: https://help.puppet.com/core/current/Content/PuppetCore/PuppetReleaseNotes/release_notes_puppet_x-8-12-0.htm'

      result[:dependency_status] = 'warning'
      result[:dependency_message] = warning
      Annotations.github_annotation('warning', "#{result[:module]} Puppet 8.12 server default", warning)

      result[:stages] << StageResult.new(
        name: 'puppet_server_default_warning',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: warning
      )

      unit_stage.status = 'passed'
      unit_stage.exit_code = 0
      unit_stage.output = [
        output,
        'Detected Puppet Core 8.12 server setting default change; unit failure downgraded to compatibility warning.'
      ].join("\n")
    end

    def downgrade_stale_reference_validate_failure(result, validate_stage)
      return if validate_stage.nil?
      return if validate_stage.status == 'passed'

      output = validate_stage.output.to_s
      return unless output.include?('REFERENCE.md is outdated')

      warning = 'REFERENCE.md is outdated; to regenerate: bundle exec rake strings:generate:reference'
      result[:documentation_status] = 'warning'
      result[:documentation_message] = warning
      Annotations.github_annotation('warning', "#{result[:module]} documentation", warning)
      result[:stages] << StageResult.new(
        name: 'documentation_warning',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: warning
      )

      validate_stage.status = 'passed'
      validate_stage.exit_code = 0
      validate_stage.output = [
        output,
        'Detected stale REFERENCE.md documentation drift; recorded as warning for compatibility classification.'
      ].join("\n")
    end
  end
end
