# frozen_string_literal: true

require 'yaml'

cfg = YAML.load_file('.puppet-module-tester.local.yml') || {}

ENV['PUPPET_CORE_API_KEY'] = cfg['puppet_core_api_key'].to_s
ENV['PUPPET_CORE_SOURCE_URL'] = cfg['puppet_core_source_url'].to_s
ENV['PUPPET_CORE_AUTH_HEADER'] = cfg['puppet_core_auth_header'].to_s
ENV['PUPPET_COMPAT_METADATA_MODE'] = cfg['puppet_compat_metadata_mode'].to_s

target = cfg['puppet_compat_target'].to_s
target = '8-latest-maintained' if target.empty?

exec(
  'ruby',
  'bin/puppet-module-tester',
  '--modules-file',
  'config/modules.json',
  '--profiles-file',
  'profiles/puppet_profiles.json',
  '--profile',
  target,
  '--workspace-dir',
  'workspace',
  '--output-dir',
  'results/local'
)
