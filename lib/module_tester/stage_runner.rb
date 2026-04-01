# frozen_string_literal: true

require 'open3'
require 'timeout'
require 'shellwords'

module ModuleTester
  class StageRunner
    def run_stage(name, command, cwd, env, timeout_seconds = nil)
      timeout_seconds = resolve_timeout(timeout_seconds)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output_buffer = String.new
      status = nil
      safe_command = Redactor.redact_sensitive(command.shelljoin)
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
                redacted_chunk = Redactor.redact_sensitive(chunk)
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
          output: Redactor.redact_sensitive(trimmed_output)
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
          output: Redactor.redact_sensitive("Timeout after #{timeout_seconds}s\n#{trimmed_output}")
        )
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

    def command_available?(name)
      exts = ENV.fetch('PATHEXT', '').split(';')
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? do |path|
        base = File.join(path, name)
        File.executable?(base) || exts.any? { |ext| File.executable?("#{base}#{ext}") }
      end
    end

    private

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
  end
end
