# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require 'time'
require 'open3'
require 'timeout'
require 'shellwords'
require 'rexml/document'
require 'cgi'
require 'yaml'
require 'tempfile'

module ModuleTester
  DEFAULT_PUPPET_CORE_SOURCE_URL = 'https://rubygems-puppetcore.puppet.com'

  StageResult = Struct.new(:name, :status, :command, :exit_code, :duration_seconds, :output, keyword_init: true)

  ModuleResult = Struct.new(
    :module,
    :ref,
    :test_mode,
    :profile,
    :started_at,
    :metadata_status,
    :metadata_message,
    :dependency_status,
    :dependency_message,
    :documentation_status,
    :documentation_message,
    :auth_status,
    :auth_message,
    :capability,
    :stages,
    :compatibility_state,
    keyword_init: true
  )

  class Runner
    SUPPORTED_RUBY_MAJOR = 3
    SUPPORTED_RUBY_MINOR = 2

    DEFAULTS = {
      modules_file: 'config/modules.json',
      profiles_file: 'profiles/puppet_profiles.json',
      profile: '8-latest-maintained',
      workspace_dir: 'workspace',
      output_dir: 'results',
      metadata_mode: ENV.fetch('PUPPET_COMPAT_METADATA_MODE', 'warn'),
      allow_acceptance: false,
      test_mode: 'unit',
      beaker_setfile: nil
    }.freeze

    def initialize(argv)
      @argv = argv
      @options = DEFAULTS.dup
      parse_options!
    end

    def run
      enforce_ruby_version!
      profiles = load_profiles(@options[:profiles_file])
      profile = profiles[@options[:profile]]
      raise "Unknown profile '#{@options[:profile]}'" unless profile

      modules = load_modules(@options[:modules_file])
      FileUtils.mkdir_p(File.join(@options[:workspace_dir], 'modules'))

      results = modules.map do |mod|
        run_module(mod, profile)
      end

      write_reports(results)
      return 1 if results.any? { |result| %w[harness_error not_compatible].include?(result[:compatibility_state]) }

      0
    rescue StandardError => e
      warn "Runner failed: #{e.message}"
      1
    end

    private

    def enforce_ruby_version!
      parts = RUBY_VERSION.split('.').map { |p| Integer(p, exception: false) }
      major = parts[0]
      minor = parts[1]

      return if major > SUPPORTED_RUBY_MAJOR || (major == SUPPORTED_RUBY_MAJOR && minor >= SUPPORTED_RUBY_MINOR)

      raise "Unsupported Ruby #{RUBY_VERSION}. This runner requires Ruby #{SUPPORTED_RUBY_MAJOR}.#{SUPPORTED_RUBY_MINOR} or later."
    end

    def parse_options!
      OptionParser.new do |opts|
        opts.on('--modules-file PATH') { |v| @options[:modules_file] = v }
        opts.on('--profiles-file PATH') { |v| @options[:profiles_file] = v }
        opts.on('--profile NAME') { |v| @options[:profile] = v }
        opts.on('--workspace-dir PATH') { |v| @options[:workspace_dir] = v }
        opts.on('--output-dir PATH') { |v| @options[:output_dir] = v }
        opts.on('--metadata-mode MODE') { |v| @options[:metadata_mode] = v }
        opts.on('--allow-acceptance') { @options[:allow_acceptance] = true }
        opts.on('--test-mode MODE') { |v| @options[:test_mode] = v.to_s.strip.downcase }
        opts.on('--beaker-setfile PATH') { |v| @options[:beaker_setfile] = v }
      end.parse!(@argv)

      unless %w[unit acceptance].include?(@options[:test_mode])
        raise "Unsupported test mode '#{@options[:test_mode]}'. Expected one of: unit, acceptance"
      end
    end

    def load_profiles(path)
      payload = JSON.parse(File.read(path))
      payload.fetch('profiles', []).each_with_object({}) do |item, acc|
        acc[item.fetch('name')] = item
      end
    end

    def load_modules(path)
      payload = JSON.parse(File.read(path))
      payload.fetch('modules', []).map do |item|
        { 'repo' => item.fetch('repo'), 'ref' => item.fetch('ref', 'main') }
      end
    end

    def run_module(mod, profile)
      repo = mod.fetch('repo')
      ref = mod.fetch('ref')
      module_name = slugify_repo(repo)
      module_dir = File.join(@options[:workspace_dir], 'modules', module_name)
      result = new_result(module_name, ref, profile.fetch('name'), @options[:test_mode])

      begin
        ok, clone_output = clone_repo(repo, ref, module_dir)
        unless ok
          result[:stages] << StageResult.new(name: 'clone', status: 'failed', command: "git clone --depth 1 --branch #{ref} #{repo}", exit_code: 1, output: clone_output)
          result[:compatibility_state] = 'inconclusive'
          return result
        end

        result[:capability] = discover_capabilities(module_dir)
        result[:metadata_status], result[:metadata_message] = evaluate_metadata(module_dir, profile.fetch('puppet_core_version'))
        annotate_metadata_warning(result)
        result[:auth_status], result[:auth_message] = auth_status(profile.fetch('gem_source_mode'))

        if result[:auth_status] != 'ok'
          result[:compatibility_state] = 'inconclusive'
          return result
        end

        env = ENV.to_h.merge(
          'PUPPET_GEM_VERSION' => profile.fetch('puppet_core_version').to_s,
          'PUPPET_COMPAT_METADATA_MODE' => @options[:metadata_mode].to_s
        )

        puppet_core_api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').strip
        if puppet_core_api_key != ''
          env['USERNAME'] = 'forge-key'
          env['PASSWORD'] = puppet_core_api_key
          env['BUNDLE_RUBYGEMS___PUPPETCORE__PUPPET__COM'] = "forge-key:#{puppet_core_api_key}"
        end

        pre_stage_count = result[:stages].length
        run_bootstrap_if_needed(module_dir, env, result, profile)
        return finish_early(result) if stages_failed_since?(result, pre_stage_count)

        pre_stage_count = result[:stages].length
        enforce_runtime_guardrails(module_dir, env, result, profile)
        return finish_early(result) if stages_failed_since?(result, pre_stage_count)

        pre_stage_count = result[:stages].length
        run_adapters(module_dir, env, profile, result)
        return finish_early(result) if stages_failed_since?(result, pre_stage_count)

        result[:compatibility_state] = resolve_state(result)
        annotate_result_state(result)
        result
      ensure
        export_stage_logs(module_name, module_dir)
      end
    end

    def finish_early(result)
      result[:compatibility_state] = resolve_state(result)
      annotate_result_state(result)
      result
    end

    def annotate_metadata_warning(result)
      return if @options[:metadata_mode] == 'fail'
      return if result[:metadata_status] == 'supported'

      github_annotation('notice', "#{result[:module]} metadata", result[:metadata_message])
    end

    def annotate_result_state(result)
      case result[:compatibility_state]
      when 'compatible'
        github_annotation('notice', result[:module], 'Compatibility run clean')
      when 'conditionally_compatible'
        details = []
        details << result[:metadata_message] unless result[:metadata_message].to_s.empty?
        details << result[:dependency_message] unless result[:dependency_message].to_s.empty?
        details << result[:documentation_message] unless result[:documentation_message].to_s.empty?
        message = details.empty? ? 'Compatibility run completed with warnings' : details.join(' | ')
        github_annotation('warning', result[:module], message)
      when 'not_compatible'
        github_annotation('error', result[:module], 'Compatibility run found failures')
      when 'harness_error'
        github_annotation('error', result[:module], 'Harness/bootstrap failure during compatibility run')
      end
    end

    def github_annotation(level, title, message)
      return unless ENV.fetch('GITHUB_ACTIONS', '').downcase == 'true'

      cleaned_title = title.to_s.gsub(/[\r\n]/, ' ').strip
      cleaned_message = message.to_s.gsub(/[\r\n]/, ' ').strip
      return if cleaned_message.empty?

      puts "::#{level} title=#{escape_github_annotation(cleaned_title)}::#{escape_github_annotation(cleaned_message)}"
    end

    def escape_github_annotation(value)
      value.to_s.gsub('%', '%25').gsub("\r", '%0D').gsub("\n", '%0A')
    end

    def new_result(module_name, ref, profile_name, test_mode)
      ModuleResult.new(
        module: module_name,
        ref: ref,
        test_mode: test_mode,
        profile: profile_name,
        started_at: Time.now.utc.iso8601,
        metadata_status: 'requires_manual_review',
        metadata_message: '',
        dependency_status: 'none',
        dependency_message: '',
        documentation_status: 'none',
        documentation_message: '',
        auth_status: 'ok',
        auth_message: '',
        capability: {},
        stages: [],
        compatibility_state: 'inconclusive'
      )
    end

    def clone_repo(repo, ref, destination)
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(File.dirname(destination))
      out, status = Open3.capture2e('git', 'clone', '--depth', '1', '--branch', ref, repo, destination)
      [status.success?, out]
    end

    def slugify_repo(repo_url)
      name = repo_url.sub(%r{/$}, '').split('/').last
      name = name.sub(/\.git$/, '')
      name.gsub(/[^a-zA-Z0-9_.-]/, '-')
    end

    def discover_capabilities(module_dir)
      gemfile = File.join(module_dir, 'Gemfile')
      gemfile_content = File.exist?(gemfile) ? File.read(gemfile) : ''
      acceptance_files = Dir.glob(File.join(module_dir, 'spec', 'acceptance', '**', '*.rb'))

      {
        'has_validate' => File.exist?(File.join(module_dir, 'Rakefile')) || File.exist?(File.join(module_dir, '.sync.yml')),
        'has_unit' => Dir.exist?(File.join(module_dir, 'spec', 'classes')) || Dir.exist?(File.join(module_dir, 'spec', 'unit')),
        'has_acceptance' => !acceptance_files.empty?,
        'windows_provider_signals' => Dir.exist?(File.join(module_dir, 'lib', 'puppet', 'provider')) ||
          Dir.exist?(File.join(module_dir, 'lib', 'puppet', 'type')),
        'uses_vox_vars' => gemfile_content.include?('OPENVOX_GEM_VERSION'),
        'requires_private_artifacts' => gemfile_content.downcase.include?('puppet')
      }
    end

    def evaluate_metadata(module_dir, puppet_version)
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

    def auth_status(gem_source_mode)
      return ['ok', ''] unless gem_source_mode == 'private'

      api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').strip
      return ['auth_missing', 'PUPPET_CORE_API_KEY is required for private Puppet Core artifact access'] if api_key.empty?

      ['ok', '']
    end

    def command_available?(name)
      exts = ENV.fetch('PATHEXT', '').split(';')
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |path|
        base = File.join(path, name)
        File.executable?(base) || exts.any? { |ext| File.executable?("#{base}#{ext}") }
      end
    end

    def run_bootstrap_if_needed(module_dir, env, result, profile)
      return unless File.exist?(File.join(module_dir, 'Gemfile')) && command_available?('bundle')

      bundle_path = ENV.fetch('PUPPET_COMPAT_BUNDLE_PATH', 'vendor/bundle').to_s.strip
      bundle_path = 'vendor/bundle' if bundle_path.empty?
      result[:stages] << run_stage('bundle_config_path', ['bundle', 'config', 'set', '--local', 'path', bundle_path], module_dir, env)
      result[:stages] << run_stage('bundle_config_multisource', ['bundle', 'config', 'set', '--local', 'disable_multisource', 'true'], module_dir, env)

      if profile.fetch('gem_source_mode') == 'private'
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
          result[:stages] << run_stage('bundle_config_source_mirror', ['bundle', 'config', 'set', '--local', 'mirror.https://rubygems.org', source_url], module_dir, env)
        end
      end

      bootstrap_stage = run_stage('bootstrap', ['bundle', 'install'], module_dir, env)
      result[:stages] << bootstrap_stage

      return if bootstrap_stage.status == 'passed'

      dependency_warning = extract_dependency_incompatibility_warning(bootstrap_stage.output)
      return if dependency_warning.nil?

      result[:dependency_status] = 'warning'
      result[:dependency_message] = dependency_warning
      github_annotation('warning', "#{result[:module]} dependency", dependency_warning)
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

      retry_stage = run_stage('bootstrap_puppet_core_retry', ['bundle', 'install'], module_dir, env)
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

    def enforce_runtime_guardrails(module_dir, env, result, profile)
      if profile.fetch('gem_source_mode') == 'private' && enforce_private_source?
        bootstrap_stage = result[:stages].find { |stage| stage.name == 'bootstrap' }
        bootstrap_output = bootstrap_stage&.output.to_s
        source_url = ENV.fetch('PUPPET_CORE_SOURCE_URL', DEFAULT_PUPPET_CORE_SOURCE_URL).strip
        unless bootstrap_output.include?(source_url)
          result[:stages] << failed_stage('enforce_private_source', "Expected bootstrap to use #{source_url} for Puppet Core gems")
        end
      end

      if enforce_no_openvox?
        result[:stages] << run_stage(
          'enforce_no_openvox',
          ['bundle', 'exec', 'ruby', '-e', "abort('openvox gem detected') if Gem::Specification.find_all_by_name('openvox').any?; puts 'openvox not detected'"] ,
          module_dir,
          env
        )
      end

      if enforce_exact_puppet_version?
        result[:stages] << run_stage(
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

      required_pdk = ENV.fetch('PUPPET_REQUIRED_PDK_VERSION', '').strip
      return if required_pdk.empty?

      unless command_available?('pdk')
        result[:stages] << failed_stage('enforce_pdk_version', "PDK is required but not installed (required: #{required_pdk})")
        return
      end

      pdk_stage = run_stage('pdk_version', ['pdk', '--version'], module_dir, env)
      result[:stages] << pdk_stage
      return if pdk_stage.status != 'passed'

      unless pdk_stage.output.to_s.match?(/\b#{Regexp.escape(required_pdk)}(\.|\b)/)
        result[:stages] << failed_stage('enforce_pdk_version', "PDK version mismatch: required #{required_pdk}, got #{pdk_stage.output.to_s.strip}")
      end
    end

    def enforce_private_source?
      ENV.fetch('PUPPET_ENFORCE_PRIVATE_SOURCE', 'true') == 'true'
    end

    def enforce_no_openvox?
      ENV.fetch('PUPPET_ENFORCE_NO_OPENVOX', 'false') == 'true'
    end

    def enforce_exact_puppet_version?
      ENV.fetch('PUPPET_ENFORCE_EXACT_PUPPET_VERSION', 'true') == 'true'
    end

    def failed_stage(name, message)
      StageResult.new(
        name: name,
        status: 'failed',
        command: nil,
        exit_code: 1,
        duration_seconds: 0,
        output: message
      )
    end

    def stages_failed_since?(result, count)
      result[:stages][count..].to_a.any? { |stage| stage.status != 'passed' }
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

    def run_adapters(module_dir, env, profile, result)
      if @options[:test_mode] == 'acceptance'
        run_acceptance_adapter(module_dir, env, result, profile)
        return
      end

      prefer_rake = result[:capability].is_a?(Hash) && result[:capability]['uses_vox_vars']

      if command_available?('pdk') && !prefer_rake
        validate_stage = run_stage('validate', ['pdk', 'validate', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
        unit_stage = run_stage('unit', ['pdk', 'test', 'unit', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        result[:stages] << unit_stage
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
        return
      end

      return unless File.exist?(File.join(module_dir, 'Rakefile')) && command_available?('bundle')

      tasks = rake_tasks(module_dir, env)
      if tasks.include?('validate')
        validate_stage = run_stage('validate', ['bundle', 'exec', 'rake', 'validate'], module_dir, env)
        result[:stages] << validate_stage
        downgrade_stale_reference_validate_failure(result, validate_stage)
      end

      if tasks.include?('spec')
        unit_stage = run_stage('unit', ['bundle', 'exec', 'rake', 'spec'], module_dir, env)
        result[:stages] << unit_stage
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      elsif tasks.include?('test')
        unit_stage = run_stage('unit', ['bundle', 'exec', 'rake', 'test'], module_dir, env)
        result[:stages] << unit_stage
        downgrade_puppet_server_default_unit_failure(result, unit_stage)
      end

    end

    def run_acceptance_adapter(module_dir, env, result, profile)
      return unless @options[:allow_acceptance]
      return unless File.exist?(File.join(module_dir, 'Rakefile')) && command_available?('bundle')

      tasks = rake_tasks(module_dir, env)
      return unless result[:capability]['has_acceptance']
      return unless tasks.include?('beaker')

      puppet_core_api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').strip

      acceptance_env = env.dup
      acceptance_env['BEAKER_HYPERVISOR'] = 'docker'

      if @options[:beaker_setfile] && !puppet_core_api_key.empty?
        # Inject Puppet Core agent install into the setfile so the container
        # ships with an authenticated Puppet Core build pre-installed.
        effective_setfile = prepare_puppet_core_setfile(
          @options[:beaker_setfile],
          profile.fetch('puppet_major'),
          puppet_core_api_key
        )
        acceptance_env['BEAKER_SETFILE'] = effective_setfile
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = 'preinstalled'
      elsif @options[:beaker_setfile]
        # No API key — fall back to FOSS puppet from public yum.puppet.com
        acceptance_env['BEAKER_SETFILE'] = File.expand_path(@options[:beaker_setfile])
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = "puppet#{profile.fetch('puppet_major')}"
      else
        acceptance_env['BEAKER_PUPPET_COLLECTION'] = "puppet#{profile.fetch('puppet_major')}"
      end

      result[:stages] << run_stage('acceptance', ['bundle', 'exec', 'rake', 'beaker'], module_dir, acceptance_env)
    end

    # Reads the base setfile YAML, appends docker_image_commands that install
    # puppet-agent from the authenticated Puppet Core yum/apt repository, and
    # writes the result to a temp file.  Returns the absolute path to the temp
    # file.  The temp file lives in the workspace dir so it survives until the
    # runner process exits.
    def prepare_puppet_core_setfile(base_path, puppet_major, api_key)
      base = YAML.safe_load(File.read(base_path), permitted_classes: [Symbol])

      hosts_key = base['HOSTS']&.keys&.first
      raise "No HOSTS entry found in setfile #{base_path}" unless hosts_key

      host_cfg = base['HOSTS'][hosts_key]
      platform = host_cfg['platform'].to_s           # e.g. "el-9-x86_64"
      variant, version, _arch = platform.split('-', 3)

      install_cmds = puppet_core_install_commands(variant, version, puppet_major, api_key)

      existing_cmds = host_cfg['docker_image_commands'] || []
      host_cfg['docker_image_commands'] = existing_cmds + install_cmds

      out_dir = File.join(@options[:workspace_dir], '.beaker-setfiles')
      FileUtils.mkdir_p(out_dir)
      out_path = File.join(out_dir, "#{File.basename(base_path, '.*')}-puppetcore.yml")
      File.write(out_path, YAML.dump(base))
      File.expand_path(out_path)
    end

    def puppet_core_install_commands(variant, version, puppet_major, api_key)
      collection = "puppet#{puppet_major}"

      case variant
      when 'el', 'centos', 'redhat', 'rocky', 'alma', 'fedora', 'amazon'
        release_rpm = "https://yum-puppetcore.puppet.com/public/#{collection}-release-#{variant}-#{version}.noarch.rpm"
        repo_file = "/etc/yum.repos.d/#{collection}-release.repo"
        [
          "rpm -Uvh #{release_rpm}",
          "sed -i 's/^#username=forge-key/username=forge-key/' #{repo_file} || sed -i '/^\\[#{collection}\\]/a username=forge-key' #{repo_file}",
          "sed -i 's/^#password=.*/password=#{api_key}/' #{repo_file} || sed -i '/^username=forge-key/a password=#{api_key}' #{repo_file}",
          "dnf install -y puppet-agent || yum install -y puppet-agent",
        ]
      when 'debian', 'ubuntu'
        codename_cmd = ". /etc/os-release && echo $VERSION_CODENAME"
        release_deb_url = "https://apt-puppetcore.puppet.com/public/#{collection}-release-$(#{codename_cmd}).deb"
        auth_file = "/etc/apt/auth.conf.d/#{collection}-puppetcore.conf"
        repo_host = 'apt-puppetcore.puppet.com'
        [
          "apt-get update -qq && apt-get install -y wget",
          "wget -O /tmp/#{collection}-release.deb \"#{release_deb_url}\"",
          "dpkg -i /tmp/#{collection}-release.deb",
          "mkdir -p /etc/apt/auth.conf.d",
          "echo 'machine #{repo_host} login forge-key password #{api_key}' > #{auth_file}",
          "apt-get update -qq && apt-get install -y puppet-agent",
        ]
      else
        raise "Unsupported platform variant '#{variant}' for Puppet Core agent install"
      end
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
      github_annotation('warning', "#{result[:module]} Puppet 8.12 server default", warning)

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
      github_annotation('warning', "#{result[:module]} documentation", warning)
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

    def rake_tasks(module_dir, env)
      listing = run_stage('rake_tasks', ['bundle', 'exec', 'rake', '-T'], module_dir, env)
      return [] unless listing.status == 'passed'

      listing.output.to_s.lines.filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?('rake ')

        stripped.split[1]
      end
    end

    def run_stage(name, command, cwd, env, timeout_seconds = nil)
      timeout_seconds = resolve_timeout(timeout_seconds)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output_buffer = String.new
      status = nil
      safe_command = redact_sensitive(command.shelljoin)
      log_file = File.join(cwd, ".stage-#{name}.log")

      puts "\n[#{Time.now.strftime('%H:%M:%S')}] => #{name}"
      puts "  Command: #{safe_command}"
      puts "  Timeout: #{timeout_seconds}s"
      puts "  Log: #{log_file}"

      begin
        Timeout.timeout(timeout_seconds) do
          File.open(log_file, 'w') do |log|
            Open3.popen2e(env, *command, chdir: cwd) do |stdin, combined, wait_thr|
              stdin.close

              loop do
                chunk = combined.readpartial(2048)
                output_buffer << chunk
                redacted_chunk = redact_sensitive(chunk)
                print redacted_chunk
                log.write(redacted_chunk)
                log.flush
              end
            rescue EOFError
              status = wait_thr.value
            end
          end
        end


        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        puts "  ✓ Completed in #{elapsed.round(2)}s (exit: #{status.exitstatus})"
        trimmed_output = output_buffer.to_s
        trimmed_output = trimmed_output[-20_000, 20_000] || trimmed_output

        StageResult.new(
          name: name,
          status: status.success? ? 'passed' : 'failed',
          command: safe_command,
          exit_code: status.exitstatus,
          duration_seconds: elapsed.round(2),
          output: redact_sensitive(trimmed_output)
        )
      rescue Timeout::Error
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        puts "  ✗ TIMEOUT after #{elapsed.round(2)}s (limit: #{timeout_seconds}s)"
        puts "  Debug log saved to: #{log_file}"

        trimmed_output = output_buffer.to_s
        trimmed_output = trimmed_output[-20_000, 20_000] || trimmed_output

        StageResult.new(
          name: name,
          status: 'failed',
          command: safe_command,
          exit_code: -1,
          duration_seconds: elapsed.round(2),
          output: redact_sensitive("Timeout after #{timeout_seconds}s\n#{trimmed_output}")
        )
      end
    end

    def resolve_timeout(explicit_timeout = nil)
      explicit_value = explicit_timeout.to_i
      return explicit_value if explicit_value.positive?

      env_value = integer_or_nil(ENV.fetch('PUPPET_STAGE_TIMEOUT_SECONDS', nil))
      return env_value if env_value && env_value.positive?

      1800
    end

    def integer_or_nil(raw)
      return nil if raw.nil?

      Integer(raw.to_s.strip, exception: false)
    end

    def redact_sensitive(text)
      value = text.to_s
      secrets = []

      api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').to_s.strip
      secrets << api_key unless api_key.empty?

      password = ENV.fetch('PASSWORD', '').to_s.strip
      secrets << password unless password.empty?

      env_credential = ENV.fetch('BUNDLE_RUBYGEMS___PUPPETCORE__PUPPET__COM', '').to_s.strip
      secrets << env_credential unless env_credential.empty?

      secrets.uniq.each do |secret|
        value = value.gsub(secret, '[REDACTED]')
        escaped = CGI.escape(secret)
        value = value.gsub(escaped, '[REDACTED]') unless escaped.empty?
      end

      value = value.gsub(/forge-key:[^\s'"@]+/, 'forge-key:[REDACTED]')
      value = value.gsub(/license-id:[^\s'"@]+/, 'license-id:[REDACTED]')
      value
    end

    def resolve_state(result)
      return 'harness_error' if result[:auth_status] != 'ok'

      harness_stage_failures = result[:stages].any? do |stage|
        next false if stage.status == 'passed'

        %w[
          clone
          bundle_config_path
          bundle_config_multisource
          bundle_config_source
          bootstrap
          bootstrap_dependency_patch
          bootstrap_puppet_core_retry
          rake_tasks
          pdk_version
        ].include?(stage.name)
      end
      return 'harness_error' if harness_stage_failures

      if @options[:test_mode] == 'acceptance'
        acceptance_stage = result[:stages].find { |stage| stage.name == 'acceptance' }
        return 'inconclusive' if acceptance_stage.nil?

        return acceptance_stage.status == 'passed' ? 'compatible' : 'not_compatible'
      end

      failing_stage = result[:stages].any? { |stage| stage.name != 'bootstrap' && stage.status != 'passed' }
      return 'not_compatible' if failing_stage

      metadata_mismatch = result[:metadata_status] != 'supported'
      return 'not_compatible' if metadata_mismatch && @options[:metadata_mode] == 'fail'
      return 'conditionally_compatible' if metadata_mismatch
      return 'conditionally_compatible' if result[:dependency_status] == 'warning'
      return 'conditionally_compatible' if result[:documentation_status] == 'warning'
      return 'inconclusive' if result[:stages].empty?

      'compatible'
    end

    def write_reports(results)
      FileUtils.mkdir_p(@options[:output_dir])
      write_json(results)
      write_junit(results)
      write_summary(results)
    end

    def export_stage_logs(module_name, module_dir)
      return unless Dir.exist?(module_dir)

      stage_logs = Dir.glob(File.join(module_dir, '.stage-*.log')).sort
      return if stage_logs.empty?

      artifacts_dir = File.join(@options[:output_dir], 'artifacts', module_name)
      FileUtils.rm_rf(artifacts_dir)
      FileUtils.mkdir_p(artifacts_dir)

      stage_logs.each do |path|
        FileUtils.cp(path, File.join(artifacts_dir, File.basename(path)))
      end
    rescue StandardError => e
      warn "Failed to export stage logs for #{module_name}: #{e.message}"
    end

    def write_json(results)
      payload = { 'results' => results.map { |r| serialize_result(r) } }
      File.write(File.join(@options[:output_dir], 'compatibility-report.json'), JSON.pretty_generate(payload))
    end

    def write_junit(results)
      doc = REXML::Document.new
      suite = doc.add_element('testsuite', { 'name' => 'puppet-module-compatibility' })
      tests = 0
      failures = 0

      results.each do |result|
        result[:stages].each do |stage|
          tests += 1
          testcase = suite.add_element('testcase', {
                                         'classname' => result[:module],
                                         'name' => stage.name,
                                         'time' => (stage.duration_seconds || 0).to_s
                                       })
          next if stage.status == 'passed'

          failures += 1
          failure = testcase.add_element('failure', { 'message' => stage.status })
          failure.text = stage.output.to_s
        end
      end

      suite.add_attribute('tests', tests.to_s)
      suite.add_attribute('failures', failures.to_s)

      formatter = REXML::Formatters::Pretty.new(2)
      formatter.compact = true
      output = +' '
      formatter.write(doc, output)
      File.write(File.join(@options[:output_dir], 'compatibility-report.junit.xml'), output)
    end

    def write_summary(results)
      lines = []
      lines << '# Puppet Module Compatibility Summary'
      lines << ''
      lines << '| Module | Profile | Metadata | Dependencies | Documentation | Compatibility |'
      lines << '|---|---|---|---|---|---|'
      results.each do |result|
        lines << "| #{result[:module]} | #{result[:profile]} | #{result[:metadata_status]} | #{result[:dependency_status]} | #{result[:documentation_status]} | #{result[:compatibility_state]} |"
      end
      File.write(File.join(@options[:output_dir], 'compatibility-summary.md'), lines.join("\n") + "\n")
    end

    def serialize_result(result)
      {
        module: result[:module],
        ref: result[:ref],
        test_mode: result[:test_mode],
        profile: result[:profile],
        started_at: result[:started_at],
        metadata_status: result[:metadata_status],
        metadata_message: result[:metadata_message],
        dependency_status: result[:dependency_status],
        dependency_message: result[:dependency_message],
        documentation_status: result[:documentation_status],
        documentation_message: result[:documentation_message],
        auth_status: result[:auth_status],
        auth_message: result[:auth_message],
        capability: result[:capability],
        stages: result[:stages].map do |stage|
          {
            name: stage.name,
            status: stage.status,
            command: stage.command,
            exit_code: stage.exit_code,
            duration_seconds: stage.duration_seconds,
            output: stage.output
          }
        end,
        compatibility_state: result[:compatibility_state]
      }
    end
  end
end
