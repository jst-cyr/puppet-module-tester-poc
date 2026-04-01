# frozen_string_literal: true

module ModuleTester
  module Classifier
    module_function

    def resolve_state(result, options)
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
          build_sut_image
          rake_tasks
          pdk_version
        ].include?(stage.name)
      end
      return 'harness_error' if harness_stage_failures

      if options[:test_mode] == 'acceptance'
        acceptance_stage = result[:stages].find { |stage| stage.name == 'acceptance' }
        return 'inconclusive' if acceptance_stage.nil?

        return acceptance_stage.status == 'passed' ? 'compatible' : 'not_compatible'
      end

      failing_stage = result[:stages].any? { |stage| stage.name != 'bootstrap' && stage.status != 'passed' }
      return 'not_compatible' if failing_stage

      metadata_mismatch = result[:metadata_status] != 'supported'
      return 'not_compatible' if metadata_mismatch && options[:metadata_mode] == 'fail'
      return 'conditionally_compatible' if metadata_mismatch
      return 'conditionally_compatible' if result[:dependency_status] == 'warning'
      return 'conditionally_compatible' if result[:documentation_status] == 'warning'
      return 'inconclusive' if result[:stages].empty?

      'compatible'
    end

    def annotate_metadata_warning(result, metadata_mode)
      return if metadata_mode == 'fail'
      return if result[:metadata_status] == 'supported'

      Annotations.github_annotation('notice', "#{result[:module]} metadata", result[:metadata_message])
    end

    def annotate_result_state(result)
      case result[:compatibility_state]
      when 'compatible'
        Annotations.github_annotation('notice', result[:module], 'Compatibility run clean')
      when 'conditionally_compatible'
        details = []
        details << result[:metadata_message] unless result[:metadata_message].to_s.empty?
        details << result[:dependency_message] unless result[:dependency_message].to_s.empty?
        details << result[:documentation_message] unless result[:documentation_message].to_s.empty?
        message = details.empty? ? 'Compatibility run completed with warnings' : details.join(' | ')
        Annotations.github_annotation('warning', result[:module], message)
      when 'not_compatible'
        Annotations.github_annotation('error', result[:module], 'Compatibility run found failures')
      when 'harness_error'
        Annotations.github_annotation('error', result[:module], 'Harness/bootstrap failure during compatibility run')
      end
    end
  end
end
