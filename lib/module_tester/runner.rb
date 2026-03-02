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

module ModuleTester
  DEFAULT_PUPPET_CORE_SOURCE_URL = 'https://rubygems-puppetcore.puppet.com'

  StageResult = Struct.new(:name, :status, :command, :exit_code, :duration_seconds, :output, keyword_init: true)

  ModuleResult = Struct.new(
    :module,
    :ref,
    :profile,
    :started_at,
    :metadata_status,
    :metadata_message,
    :auth_status,
    :auth_message,
    :capability,
    :stages,
    :compatibility_state,
    keyword_init: true
  )

  class Runner
    DEFAULTS = {
      modules_file: 'config/modules.json',
      profiles_file: 'profiles/puppet_profiles.json',
      profile: '8-latest-maintained',
      workspace_dir: 'workspace',
      output_dir: 'results',
      metadata_mode: ENV.fetch('PUPPET_COMPAT_METADATA_MODE', 'warn'),
      allow_acceptance: false
    }.freeze

    def initialize(argv)
      @argv = argv
      @options = DEFAULTS.dup
      parse_options!
    end

    def run
      profiles = load_profiles(@options[:profiles_file])
      profile = profiles[@options[:profile]]
      raise "Unknown profile '#{@options[:profile]}'" unless profile

      modules = load_modules(@options[:modules_file])
      FileUtils.mkdir_p(File.join(@options[:workspace_dir], 'modules'))

      results = modules.map do |mod|
        run_module(mod, profile)
      end

      write_reports(results)
      return 1 if results.any? { |result| result[:compatibility_state] == 'harness_error' }

      0
    rescue StandardError => e
      warn "Runner failed: #{e.message}"
      1
    end

    private

    def parse_options!
      OptionParser.new do |opts|
        opts.on('--modules-file PATH') { |v| @options[:modules_file] = v }
        opts.on('--profiles-file PATH') { |v| @options[:profiles_file] = v }
        opts.on('--profile NAME') { |v| @options[:profile] = v }
        opts.on('--workspace-dir PATH') { |v| @options[:workspace_dir] = v }
        opts.on('--output-dir PATH') { |v| @options[:output_dir] = v }
        opts.on('--metadata-mode MODE') { |v| @options[:metadata_mode] = v }
        opts.on('--allow-acceptance') { @options[:allow_acceptance] = true }
      end.parse!(@argv)
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
      result = new_result(module_name, ref, profile.fetch('name'))

      ok, clone_output = clone_repo(repo, ref, module_dir)
      unless ok
        result[:stages] << StageResult.new(name: 'clone', status: 'failed', command: "git clone --depth 1 --branch #{ref} #{repo}", exit_code: 1, output: clone_output)
        result[:compatibility_state] = 'inconclusive'
        return result
      end

      result[:capability] = discover_capabilities(module_dir)
      result[:metadata_status], result[:metadata_message] = evaluate_metadata(module_dir, profile.fetch('puppet_core_version'))
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
      result
    end

    def finish_early(result)
      result[:compatibility_state] = resolve_state(result)
      result
    end

    def new_result(module_name, ref, profile_name)
      ModuleResult.new(
        module: module_name,
        ref: ref,
        profile: profile_name,
        started_at: Time.now.utc.iso8601,
        metadata_status: 'requires_manual_review',
        metadata_message: '',
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

      result[:stages] << run_stage('bundle_config_path', ['bundle', 'config', 'set', '--local', 'path', 'vendor/bundle'], module_dir, env)
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

      result[:stages] << run_stage('bootstrap', ['bundle', 'install'], module_dir, env)
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
            "spec=Gem::Specification.find_all_by_name('puppet').max_by(&:version); abort('puppet gem not installed') unless spec; expected=ENV.fetch('PUPPET_GEM_VERSION'); abort(\"puppet #{spec.version} != #{expected}\") unless spec.version.to_s == expected; puts \"puppet #{spec.version}\""
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
      if command_available?('pdk')
        result[:stages] << run_stage('validate', ['pdk', 'validate', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        result[:stages] << run_stage('unit', ['pdk', 'test', 'unit', '--puppet-version', profile.fetch('puppet_major').to_s], module_dir, env)
        return
      end

      return unless File.exist?(File.join(module_dir, 'Rakefile')) && command_available?('bundle')

      tasks = rake_tasks(module_dir, env)
      result[:stages] << run_stage('validate', ['bundle', 'exec', 'rake', 'validate'], module_dir, env) if tasks.include?('validate')

      if tasks.include?('spec')
        result[:stages] << run_stage('unit', ['bundle', 'exec', 'rake', 'spec'], module_dir, env)
      elsif tasks.include?('test')
        result[:stages] << run_stage('unit', ['bundle', 'exec', 'rake', 'test'], module_dir, env)
      end

      if @options[:allow_acceptance] && result[:capability]['has_acceptance'] && tasks.include?('beaker')
        result[:stages] << run_stage('acceptance', ['bundle', 'exec', 'rake', 'beaker'], module_dir, env)
      end
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

    def run_stage(name, command, cwd, env, timeout_seconds = 1800)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output = ''
      status = nil
      safe_command = redact_sensitive(command.shelljoin)

      begin
        Timeout.timeout(timeout_seconds) do
          output, status = Open3.capture2e(env, *command, chdir: cwd)
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        trimmed_output = output.to_s
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
        trimmed_output = output.to_s
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
          rake_tasks
          pdk_version
        ].include?(stage.name)
      end
      return 'harness_error' if harness_stage_failures

      failing_stage = result[:stages].any? { |stage| stage.name != 'bootstrap' && stage.status != 'passed' }
      return 'not_compatible' if failing_stage

      metadata_mismatch = result[:metadata_status] != 'supported'
      return 'not_compatible' if metadata_mismatch && @options[:metadata_mode] == 'fail'
      return 'conditionally_compatible' if metadata_mismatch
      return 'inconclusive' if result[:stages].empty?

      'compatible'
    end

    def write_reports(results)
      FileUtils.mkdir_p(@options[:output_dir])
      write_json(results)
      write_junit(results)
      write_summary(results)
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
      lines << '| Module | Profile | Metadata | Compatibility |'
      lines << '|---|---|---|---|'
      results.each do |result|
        lines << "| #{result[:module]} | #{result[:profile]} | #{result[:metadata_status]} | #{result[:compatibility_state]} |"
      end
      File.write(File.join(@options[:output_dir], 'compatibility-summary.md'), lines.join("\n") + "\n")
    end

    def serialize_result(result)
      {
        module: result[:module],
        ref: result[:ref],
        profile: result[:profile],
        started_at: result[:started_at],
        metadata_status: result[:metadata_status],
        metadata_message: result[:metadata_message],
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
