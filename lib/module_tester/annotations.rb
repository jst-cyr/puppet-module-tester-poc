# frozen_string_literal: true

module ModuleTester
  module Annotations
    module_function

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
  end
end
