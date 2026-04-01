# frozen_string_literal: true

module ModuleTester
  class Guardrails
    def initialize(stage_runner)
      @stage = stage_runner
    end

    def enforce(module_dir, env, result, profile)
      enforce_private_source(result, profile)
      enforce_no_openvox(module_dir, env, result)
      enforce_puppet_version(module_dir, env, result)
      enforce_pdk_version(module_dir, env, result)
    end

    private

    def enforce_private_source(result, profile)
      return unless profile.fetch('gem_source_mode') == 'private'
      return unless ENV.fetch('PUPPET_ENFORCE_PRIVATE_SOURCE', 'true') == 'true'

      bootstrap_stage = result[:stages].find { |s| s.name == 'bootstrap' }
      bootstrap_output = bootstrap_stage&.output.to_s
      source_url = ENV.fetch('PUPPET_CORE_SOURCE_URL', DEFAULT_PUPPET_CORE_SOURCE_URL).strip
      unless bootstrap_output.include?(source_url)
        result[:stages] << Result.failed_stage('enforce_private_source', "Expected bootstrap to use #{source_url} for Puppet Core gems")
      end
    end

    def enforce_no_openvox(module_dir, env, result)
      return unless ENV.fetch('PUPPET_ENFORCE_NO_OPENVOX', 'false') == 'true'

      result[:stages] << @stage.run_stage(
        'enforce_no_openvox',
        ['bundle', 'exec', 'ruby', '-e', "abort('openvox gem detected') if Gem::Specification.find_all_by_name('openvox').any?; puts 'openvox not detected'"],
        module_dir,
        env
      )
    end

    def enforce_puppet_version(module_dir, env, result)
      return unless ENV.fetch('PUPPET_ENFORCE_EXACT_PUPPET_VERSION', 'true') == 'true'

      result[:stages] << @stage.run_stage(
        'enforce_puppet_version',
        [
          'bundle',
          'exec',
          'ruby',
          '-e',
          "spec=Gem::Specification.find_all_by_name('puppet').max_by(&:version); abort('puppet gem not installed') unless spec; expected=ENV.fetch('PUPPET_GEM_VERSION'); abort(\"puppet \#{spec.version} != \#{expected}\") unless spec.version.to_s == expected; puts \"puppet \#{spec.version}\""
        ],
        module_dir,
        env
      )
    end

    def enforce_pdk_version(module_dir, env, result)
      required_pdk = ENV.fetch('PUPPET_REQUIRED_PDK_VERSION', '').strip
      return if required_pdk.empty?

      unless @stage.command_available?('pdk')
        result[:stages] << Result.failed_stage('enforce_pdk_version', "PDK is required but not installed (required: #{required_pdk})")
        return
      end

      pdk_stage = @stage.run_stage('pdk_version', ['pdk', '--version'], module_dir, env)
      result[:stages] << pdk_stage
      return if pdk_stage.status != 'passed'

      unless pdk_stage.output.to_s.match?(/\b#{Regexp.escape(required_pdk)}(\.|\b)/)
        result[:stages] << Result.failed_stage('enforce_pdk_version', "PDK version mismatch: required #{required_pdk}, got #{pdk_stage.output.to_s.strip}")
      end
    end
  end
end
