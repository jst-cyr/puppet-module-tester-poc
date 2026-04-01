# frozen_string_literal: true

require 'json'
require 'fileutils'

module ModuleTester
  class Reporting
    def initialize(output_dir)
      @output_dir = output_dir
    end

    def write_reports(results)
      FileUtils.mkdir_p(@output_dir)
      write_json(results)
      write_summary(results)
    end

    def export_stage_logs(module_name, module_dir)
      return unless Dir.exist?(module_dir)

      stage_logs = Dir.glob(File.join(module_dir, '.stage-*.log')).sort
      return if stage_logs.empty?

      artifacts_dir = File.join(@output_dir, 'artifacts', module_name)
      FileUtils.rm_rf(artifacts_dir)
      FileUtils.mkdir_p(artifacts_dir)

      stage_logs.each do |path|
        FileUtils.cp(path, File.join(artifacts_dir, File.basename(path)))
      end
    rescue StandardError => e
      warn "Failed to export stage logs for #{module_name}: #{e.message}"
    end

    private

    def write_json(results)
      payload = { 'results' => results.map { |r| serialize_result(r) } }
      File.write(File.join(@output_dir, 'compatibility-report.json'), JSON.pretty_generate(payload))
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
      File.write(File.join(@output_dir, 'compatibility-summary.md'), lines.join("\n") + "\n")
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
            command: Redactor.redact_sensitive(stage.command),
            exit_code: stage.exit_code,
            duration_seconds: stage.duration_seconds,
            output: Redactor.redact_sensitive(stage.output)
          }
        end,
        compatibility_state: result[:compatibility_state]
      }
    end
  end
end
