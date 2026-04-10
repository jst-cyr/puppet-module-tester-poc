# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require 'open3'

module ModuleTester
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
      beaker_setfile: nil,
      docker_mode: 'sshd'
    }.freeze

    def initialize(argv)
      @argv = argv
      @options = DEFAULTS.dup
      parse_options!

      @stage_runner = StageRunner.new
      @bootstrap   = Bootstrap.new(@stage_runner)
      @guardrails  = Guardrails.new(@stage_runner)
      @docker      = Docker.new(@stage_runner, @options[:workspace_dir])
      @adapters    = Adapters.new(@stage_runner, @docker, @options)
      @reporting   = Reporting.new(@options[:output_dir])
    end

    def run
      enforce_ruby_version!
      profiles = load_profiles(@options[:profiles_file])
      profile = profiles[@options[:profile]]
      raise "Unknown profile '#{@options[:profile]}'" unless profile

      modules = load_modules(@options[:modules_file])
      FileUtils.mkdir_p(File.join(@options[:workspace_dir], 'modules'))

      results = modules.map { |mod| run_module(mod, profile) }

      @reporting.write_reports(results)
      return 1 if results.any? { |r| %w[harness_error not_compatible].include?(r[:compatibility_state]) }

      0
    rescue StandardError => e
      warn "Runner failed: #{e.message}"
      1
    end

    private

    # ── Per-module pipeline ──────────────────────────────────────────────
    #
    # Each module flows through a fixed sequence of stages. If any stage
    # group fails, the pipeline short-circuits and classifies the result.
    #
    def run_module(mod, profile)
      repo = mod.fetch('repo')
      ref  = mod.fetch('ref')
      module_name = slugify_repo(repo)
      module_dir  = File.join(@options[:workspace_dir], 'modules', module_name)
      result = Result.build(module_name, ref, profile.fetch('name'), @options[:test_mode])

      begin
        # 1. Clone the module repository
        ok, clone_output = clone_repo(repo, ref, module_dir)
        unless ok
          result[:stages] << StageResult.new(name: 'clone', status: 'failed',
            command: "git clone --depth 1 --branch #{ref} #{repo}", exit_code: 1, output: clone_output)
          result[:compatibility_state] = 'inconclusive'
          return result
        end

        # 2. Discover capabilities and evaluate metadata compatibility
        result[:capability] = discover_capabilities(module_dir)
        result[:metadata_status], result[:metadata_message] =
          Metadata.evaluate(module_dir, profile.fetch('puppet_core_version'))
        Classifier.annotate_metadata_warning(result, @options[:metadata_mode])

        # 3. Verify authentication for private artifact sources
        result[:auth_status], result[:auth_message] = auth_status(profile.fetch('gem_source_mode'))
        if result[:auth_status] != 'ok'
          result[:compatibility_state] = 'inconclusive'
          return result
        end

        # 4. Build environment and bootstrap dependencies
        env = build_environment(profile)

        pre = result[:stages].length
        @bootstrap.run(module_dir, env, result, profile)
        return finish(result) if Result.stages_failed_since?(result, pre)

        # 5. Enforce runtime guardrails (gem source, puppet version, etc.)
        pre = result[:stages].length
        @guardrails.enforce(module_dir, env, result, profile)
        return finish(result) if Result.stages_failed_since?(result, pre)

        # 6. Run test adapters (unit or acceptance)
        pre = result[:stages].length
        @adapters.run(module_dir, env, profile, result)
        return finish(result) if Result.stages_failed_since?(result, pre)

        finish(result)
      ensure
        @reporting.export_stage_logs(module_name, module_dir)
      end
    end

    def finish(result)
      result[:compatibility_state] = Classifier.resolve_state(result, @options)
      Classifier.annotate_result_state(result)
      result
    end

    # ── Setup helpers ────────────────────────────────────────────────────

    def enforce_ruby_version!
      parts = RUBY_VERSION.split('.').map { |p| Integer(p, exception: false) }
      major = parts[0]
      minor = parts[1]

      return if major > SUPPORTED_RUBY_MAJOR || (major == SUPPORTED_RUBY_MAJOR && minor >= SUPPORTED_RUBY_MINOR)

      raise "Unsupported Ruby #{RUBY_VERSION}. This runner requires Ruby #{SUPPORTED_RUBY_MAJOR}.#{SUPPORTED_RUBY_MINOR} or later."
    end

    def parse_options!
      OptionParser.new do |opts|
        opts.on('--modules-file PATH')  { |v| @options[:modules_file] = v }
        opts.on('--profiles-file PATH') { |v| @options[:profiles_file] = v }
        opts.on('--profile NAME')       { |v| @options[:profile] = v }
        opts.on('--workspace-dir PATH') { |v| @options[:workspace_dir] = v }
        opts.on('--output-dir PATH')    { |v| @options[:output_dir] = v }
        opts.on('--metadata-mode MODE') { |v| @options[:metadata_mode] = v }
        opts.on('--allow-acceptance')   { @options[:allow_acceptance] = true }
        opts.on('--test-mode MODE')     { |v| @options[:test_mode] = v.to_s.strip.downcase }
        opts.on('--beaker-setfile PATH') { |v| @options[:beaker_setfile] = v }
        opts.on('--docker-mode MODE')   { |v| @options[:docker_mode] = v.to_s.strip.downcase }
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

    # ── Module-level helpers ─────────────────────────────────────────────

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

    def auth_status(gem_source_mode)
      return ['ok', ''] unless gem_source_mode == 'private'

      api_key = ENV.fetch('PUPPET_CORE_API_KEY', '').strip
      return ['auth_missing', 'PUPPET_CORE_API_KEY is required for private Puppet Core artifact access'] if api_key.empty?

      ['ok', '']
    end

    def build_environment(profile)
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

      env
    end
  end
end
