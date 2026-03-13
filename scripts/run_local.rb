# frozen_string_literal: true

require 'yaml'

cfg = YAML.load_file('.puppet-module-tester.local.yml') || {}

def normalize_module_selectors(value)
  case value
  when Array
    value
  when String
    value.split(',')
  else
    []
  end.map(&:to_s).map(&:strip).reject(&:empty?).uniq
end

ENV['PUPPET_CORE_API_KEY'] = cfg['puppet_core_api_key'].to_s
ENV['PUPPET_CORE_SOURCE_URL'] = cfg['puppet_core_source_url'].to_s
ENV['PUPPET_CORE_AUTH_HEADER'] = cfg['puppet_core_auth_header'].to_s
ENV['PUPPET_COMPAT_METADATA_MODE'] = cfg['puppet_compat_metadata_mode'].to_s
ENV['PUPPET_COMPAT_BUNDLE_PATH'] = cfg['puppet_compat_bundle_path'].to_s

if ENV['PUPPET_COMPAT_BUNDLE_PATH'].strip.empty?
  ENV['PUPPET_COMPAT_BUNDLE_PATH'] = 'C:/Temp/pmt-bundle'
end

target = cfg['puppet_compat_target'].to_s
target = '8-latest-maintained' if target.empty?

workspace_dir = cfg['puppet_compat_workspace_dir'].to_s
workspace_dir = 'C:/Temp/pmt-workspace' if workspace_dir.empty?

output_dir = cfg['puppet_compat_output_dir'].to_s
output_dir = 'results/local' if output_dir.empty?

module_selectors = normalize_module_selectors(cfg['puppet_compat_modules'])

command = [
  'ruby',
  'bin/puppet-module-tester',
  '--modules-file',
  'config/modules.json',
  '--profiles-file',
  'profiles/puppet_profiles.json',
  '--profile',
  target,
  '--workspace-dir',
  workspace_dir,
  '--output-dir',
  output_dir
]

unless module_selectors.empty?
  command << '--modules'
  command << module_selectors.join(',')
end

exec(*command)
