# frozen_string_literal: true

require 'json'

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
      unit_env = build_fact_probe_env(module_dir, env)
      prefer_rake = result[:capability].is_a?(Hash) && result[:capability]['uses_vox_vars']

      if @stage.command_available?('pdk') && !prefer_rake
        validate_stage = @stage.run_stage('validate', ['pdk', 'validate', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, unit_env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
        unit_stage = @stage.run_stage('unit', ['pdk', 'test', 'unit', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, unit_env)
        result[:stages] << unit_stage
        annotate_fact_runtime_provider(module_dir, result)
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
        return
      end

      return unless File.exist?(File.join(module_dir, 'Rakefile')) && @stage.command_available?('bundle')

      tasks = @stage.rake_tasks(module_dir, unit_env)
      if tasks.include?('validate')
        validate_stage = @stage.run_stage('validate', ['bundle', 'exec', 'rake', 'validate'], module_dir, unit_env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
      end

      if tasks.include?('spec')
        unit_stage = @stage.run_stage('unit', ['bundle', 'exec', 'rake', 'spec'], module_dir, unit_env)
        result[:stages] << unit_stage
        annotate_fact_runtime_provider(module_dir, result)
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      elsif tasks.include?('test')
        unit_stage = @stage.run_stage('unit', ['bundle', 'exec', 'rake', 'test'], module_dir, unit_env)
        result[:stages] << unit_stage
        annotate_fact_runtime_provider(module_dir, result)
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      end
    end

    def build_fact_probe_env(module_dir, env)
      probe_path = File.expand_path('fact_runtime_probe.rb', __dir__)
      output_path = File.join(module_dir, '.fact-runtime-probe.json')

      File.delete(output_path) if File.exist?(output_path)

      probe_env = env.dup
      rubyopt = probe_env.fetch('RUBYOPT', '').to_s.strip
      require_probe = "-r#{probe_path}"
      probe_env['RUBYOPT'] = rubyopt.empty? ? require_probe : "#{rubyopt} #{require_probe}"
      probe_env['PUPPET_FACT_RUNTIME_PROBE_ENABLED'] = 'true'
      probe_env['PUPPET_FACT_RUNTIME_PROBE_OUTPUT'] = output_path
      probe_env
    end

    def annotate_fact_runtime_provider(module_dir, result)
      output_path = File.join(module_dir, '.fact-runtime-probe.json')
      unless File.exist?(output_path)
        result[:stages] << StageResult.new(
          name: 'fact_runtime_probe',
          status: 'passed',
          command: nil,
          exit_code: 0,
          duration_seconds: 0,
          output: 'Fact runtime probe data not found; no runtime fact-provider signal captured.'
        )
        return
      end

      payload = JSON.parse(File.read(output_path))
      used_runtime_fact_api = payload['runtime_fact_api_used'] == true
      providers_seen = Array(payload['providers_seen']).map(&:to_s)
      call_count = payload['call_count'].to_i

      summary = "runtime_fact_api_used=#{used_runtime_fact_api} call_count=#{call_count} providers_seen=#{providers_seen.join(',')}"
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
