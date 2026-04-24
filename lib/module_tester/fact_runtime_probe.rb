# frozen_string_literal: true

require 'json'

module ModuleTester
  module FactRuntimeProbe
    module_function

    MAX_CALL_SAMPLES = 20

    def state
      @state ||= {
        hooks_installed: false,
        runtime_fact_api_used: false,
        call_count: 0,
        providers_seen: [],
        calls: [],
        errors: []
      }
    end

    def enabled?
      ENV.fetch('PUPPET_FACT_RUNTIME_PROBE_ENABLED', '').downcase == 'true'
    end

    def output_path
      ENV.fetch('PUPPET_FACT_RUNTIME_PROBE_OUTPUT', '').to_s.strip
    end

    def install_hooks_if_possible
      return unless enabled?
      return if state[:hooks_installed]
      return unless Object.const_defined?(:Facter)

      facter = Object.const_get(:Facter)
      singleton = class << facter; self; end
      instrumented = false

      %i[value fact].each do |method_name|
        next unless facter.respond_to?(method_name, true)

        original = "__pmt_probe_original_#{method_name}".to_sym
        next if singleton.method_defined?(original) || singleton.private_method_defined?(original)

        singleton.class_eval do
          alias_method original, method_name
          define_method(method_name) do |*args, **kwargs, &block|
            ModuleTester::FactRuntimeProbe.record_call(method_name, args)
            if kwargs.empty?
              send(original, *args, &block)
            else
              send(original, *args, **kwargs, &block)
            end
          end
        end

        instrumented = true
      end

      state[:hooks_installed] = instrumented
    rescue StandardError => e
      state[:errors] << "hook_install_failed: #{e.class}: #{e.message}"
    end

    def record_call(method_name, args)
      state[:runtime_fact_api_used] = true
      state[:call_count] += 1

      provider, source = detect_provider
      providers = state[:providers_seen]
      providers << provider if provider && !providers.include?(provider)

      return if state[:calls].length >= MAX_CALL_SAMPLES

      state[:calls] << {
        method: method_name.to_s,
        arg0: args[0].to_s,
        provider: provider,
        source: source
      }
    rescue StandardError => e
      state[:errors] << "record_call_failed: #{e.class}: #{e.message}"
    end

    def detect_provider
      return [nil, nil] unless Object.const_defined?(:Facter)

      facter = Object.const_get(:Facter)
      source = source_for(facter, :value) || source_for(facter, :fact)
      return ['openfact', source] if source&.include?('/gems/openfact-')
      return ['facter', source] if source&.include?('/gems/facter-')

      loaded = $LOADED_FEATURES.join("\n")
      return ['openfact', source] if loaded.include?('/gems/openfact-')
      return ['facter', source] if loaded.include?('/gems/facter-')

      [nil, source]
    rescue StandardError => e
      state[:errors] << "detect_provider_failed: #{e.class}: #{e.message}"
      [nil, nil]
    end

    def source_for(facter, method_name)
      return nil unless facter.respond_to?(method_name, true)

      facter.method(method_name).source_location&.first
    rescue StandardError
      nil
    end

    def write_report
      return unless enabled?
      return if output_path.empty?

      payload = {
        runtime_fact_api_used: state[:runtime_fact_api_used],
        call_count: state[:call_count],
        providers_seen: state[:providers_seen],
        hooks_installed: state[:hooks_installed],
        calls: state[:calls],
        errors: state[:errors]
      }

      File.write(output_path, JSON.generate(payload))
    rescue StandardError
      # Best-effort reporting only; never fail test runs because diagnostics failed.
      nil
    end
  end
end

if ENV.fetch('PUPPET_FACT_RUNTIME_PROBE_ENABLED', '').downcase == 'true'
  module Kernel
    unless method_defined?(:__pmt_probe_original_require)
      alias __pmt_probe_original_require require

      def require(path)
        result = __pmt_probe_original_require(path)
        if path.to_s.include?('facter') || path.to_s.include?('openfact')
          ModuleTester::FactRuntimeProbe.install_hooks_if_possible
        end
        result
      end
    end
  end

  ModuleTester::FactRuntimeProbe.install_hooks_if_possible
  at_exit { ModuleTester::FactRuntimeProbe.write_report }
end
