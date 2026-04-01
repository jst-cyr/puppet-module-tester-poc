# frozen_string_literal: true

module ModuleTester
  DEFAULT_PUPPET_CORE_SOURCE_URL = 'https://rubygems-puppetcore.puppet.com'

  class Bootstrap
    def initialize(stage_runner)
      @stage = stage_runner
    end

    def run(module_dir, env, result, profile)
      return unless File.exist?(File.join(module_dir, 'Gemfile')) && @stage.command_available?('bundle')

      configure_bundle(module_dir, env, result)
      configure_source(module_dir, env, result, profile)

      bootstrap_stage = @stage.run_stage('bootstrap', ['bundle', 'install'], module_dir, env)
      result[:stages] << bootstrap_stage

      return if bootstrap_stage.status == 'passed'

      attempt_dependency_recovery(module_dir, env, result, bootstrap_stage)
    end

    private

    def configure_bundle(module_dir, env, result)
      bundle_path = ENV.fetch('PUPPET_COMPAT_BUNDLE_PATH', 'vendor/bundle').to_s.strip
      bundle_path = 'vendor/bundle' if bundle_path.empty?
      result[:stages] << @stage.run_stage('bundle_config_path', ['bundle', 'config', 'set', '--local', 'path', bundle_path], module_dir, env)
      result[:stages] << @stage.run_stage('bundle_config_multisource', ['bundle', 'config', 'set', '--local', 'disable_multisource', 'true'], module_dir, env)
    end

    def configure_source(module_dir, env, result, profile)
      return unless profile.fetch('gem_source_mode') == 'private'

      source_url = ENV.fetch('PUPPET_CORE_SOURCE_URL', DEFAULT_PUPPET_CORE_SOURCE_URL).strip
      result[:stages] << StageResult.new(
        name: 'bundle_config_source',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: "Using authenticated source: #{source_url}"
      )

      if split_source_mode?
        overlay_gemfile = write_split_gemfile(module_dir, profile, source_url)
        env['BUNDLE_GEMFILE'] = overlay_gemfile
        display_gemfile = File.basename(overlay_gemfile)
        result[:stages] << StageResult.new(
          name: 'bundle_config_split_gemfile',
          status: 'passed',
          command: nil,
          exit_code: 0,
          duration_seconds: 0,
          output: "Using split-source Gemfile: #{display_gemfile}"
        )
      else
        result[:stages] << @stage.run_stage('bundle_config_source_mirror', ['bundle', 'config', 'set', '--local', 'mirror.https://rubygems.org', source_url], module_dir, env)
      end
    end

    def attempt_dependency_recovery(module_dir, env, result, bootstrap_stage)
      dependency_warning = extract_dependency_incompatibility_warning(bootstrap_stage.output)
      return if dependency_warning.nil?

      result[:dependency_status] = 'warning'
      result[:dependency_message] = dependency_warning
      Annotations.github_annotation('warning', "#{result[:module]} dependency", dependency_warning)
      result[:stages] << StageResult.new(
        name: 'dependency_warning',
        status: 'passed',
        command: nil,
        exit_code: 0,
        duration_seconds: 0,
        output: dependency_warning
      )

      patch_info = patch_module_gemfile_for_puppet_core(module_dir)
      result[:stages] << StageResult.new(
        name: 'bootstrap_dependency_patch',
        status: patch_info[:changed] ? 'passed' : 'failed',
        command: nil,
        exit_code: patch_info[:changed] ? 0 : 1,
        duration_seconds: 0,
        output: patch_info[:message]
      )
      return unless patch_info[:changed]

      retry_stage = @stage.run_stage('bootstrap_puppet_core_retry', ['bundle', 'install'], module_dir, env)
      result[:stages] << retry_stage
      return unless retry_stage.status == 'passed'

      bootstrap_stage.status = 'passed'
      bootstrap_stage.exit_code = 0
      bootstrap_stage.output = [bootstrap_stage.output.to_s, 'Recovered by applying Puppet Core-compatible gem constraints and retrying bundle install.'].join("\n")
    end

    def extract_dependency_incompatibility_warning(output)
      text = output.to_s
      return nil unless text.include?('Could not find compatible versions') || text.include?('version solving has failed')

      return nil unless text.match?(/depends on puppet-resource_api/i)

      'Dependency incompatibility detected during bundle install; applying Puppet Core-compatible gem constraints and retrying.'
    end

    def patch_module_gemfile_for_puppet_core(module_dir)
      gemfile_path = File.join(module_dir, 'Gemfile')
      return { changed: false, message: 'Gemfile not found; cannot apply Puppet Core dependency fallback.' } unless File.exist?(gemfile_path)

      original = File.read(gemfile_path)
      updated = original.dup
      changes = []

      replacements = {
        'voxpupuli-release' => '~> 5.2',
        'openvox-strings' => '< 6.1.0',
        'openvox' => '< 8.24',
        'puppet-resource_api' => '~> 1.9'
      }

      replacements.each do |gem_name, requirement|
        updated, changed = force_gem_requirement(updated, gem_name, requirement)
        changes << "#{gem_name}=#{requirement}" if changed
      end

      if !updated.include?("gem 'puppet-resource_api'") && !updated.include?("gem \"puppet-resource_api\"")
        updated << "\n# Added by compatibility harness for Puppet Core dependency resolution\ngem 'puppet-resource_api', '~> 1.9'\n"
        changes << 'puppet-resource_api=~> 1.9 (added)'
      end

      return { changed: false, message: 'No compatible Gemfile overrides could be applied.' } if updated == original

      backup_path = File.join(module_dir, 'Gemfile.before-puppet-core-compat')
      File.write(backup_path, original)
      File.write(gemfile_path, updated)

      {
        changed: true,
        message: "Applied Puppet Core Gemfile overrides: #{changes.join(', ')}"
      }
    rescue StandardError => e
      { changed: false, message: "Failed to patch Gemfile for Puppet Core fallback: #{e.message}" }
    end

    def force_gem_requirement(content, gem_name, requirement)
      changed = false
      pattern = /^\s*gem\s+['\"]#{Regexp.escape(gem_name)}['\"](?:\s*,\s*([^\n#]+))?/m

      updated = content.gsub(pattern) do |line|
        new_line = if line.match?(/,\s*['\"][^'\"]+['\"]/)
                     line.sub(/,\s*['\"][^'\"]+['\"]/m, ", '#{requirement}'")
                   else
                     line.sub(/(['\"]#{Regexp.escape(gem_name)}['\"])/, "\\1, '#{requirement}'")
                   end
        changed ||= (new_line != line)
        new_line
      end

      [updated, changed]
    end

    def split_source_mode?
      ENV.fetch('PUPPET_SPLIT_SOURCES', 'true') == 'true'
    end

    def write_split_gemfile(module_dir, profile, source_url)
      overlay_gemfile = File.expand_path('Gemfile.puppetcore', module_dir)
      puppet_version = profile.fetch('puppet_core_version').to_s
      facter_version = profile.fetch('facter_version', '').to_s

      lines = []
      lines << "eval_gemfile 'Gemfile'"
      lines << ""
      lines << "source '#{source_url}' do"
      lines << "  gem 'puppet', '= #{puppet_version}', require: false"
      lines << "  gem 'facter', '= #{facter_version}', require: false" unless facter_version.empty?
      lines << "end"
      lines << ""

      File.write(overlay_gemfile, lines.join("\n"))
      overlay_gemfile
    end
  end
end
