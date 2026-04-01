# frozen_string_literal: true

require 'time'

module ModuleTester
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

  module Result
    module_function

    def build(module_name, ref, profile_name, test_mode)
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
  end
end
