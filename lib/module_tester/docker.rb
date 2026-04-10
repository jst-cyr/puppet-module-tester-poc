# frozen_string_literal: true

require 'yaml'
require 'fileutils'

module ModuleTester
  class Docker
    def initialize(stage_runner, workspace_dir)
      @stage = stage_runner
      @workspace_dir = workspace_dir
    end

    # Builds a Docker image with puppet-agent from authenticated Puppet Core
    # repos.  The API key is used ONLY during the docker build and is removed
    # from the resulting image layers.  Returns [image_tag, StageResult].
    def build_puppet_core_image(base_setfile_path, puppet_major, api_key, docker_mode: 'sshd')
      base = YAML.safe_load(File.read(base_setfile_path), permitted_classes: [Symbol])
      hosts_key = base['HOSTS']&.keys&.first
      raise "No HOSTS entry found in setfile #{base_setfile_path}" unless hosts_key

      host_cfg = base['HOSTS'][hosts_key]
      base_image = host_cfg['image'].to_s
      platform = host_cfg['platform'].to_s
      variant, version, _arch = platform.split('-', 3)
      existing_cmds = host_cfg['docker_image_commands'] || []

      image_tag = "puppet-core-sut:#{File.basename(base_setfile_path, '.*')}"
      dockerfile = puppet_core_dockerfile(base_image, existing_cmds, variant, version, puppet_major, docker_mode: docker_mode)
      return [image_tag, Result.failed_stage('build_sut_image', 'Docker CLI not found in PATH')] unless @stage.command_available?('docker')

      build_dir = File.expand_path(File.join(@workspace_dir, '.docker-build'))
      FileUtils.mkdir_p(build_dir)
      dockerfile_path = File.join(build_dir, 'Dockerfile')
      File.write(dockerfile_path, dockerfile)
      return [image_tag, Result.failed_stage('build_sut_image', "Docker build directory missing: #{build_dir}")] unless Dir.exist?(build_dir)
      return [image_tag, Result.failed_stage('build_sut_image', "Dockerfile missing: #{dockerfile_path}")] unless File.exist?(dockerfile_path)

      # Build with BuildKit secrets so the key is never stored in image metadata.
      build_cmd = [
        'docker', 'build',
        '--no-cache',
        '--secret', 'id=puppet_core_api_key,env=PUPPET_CORE_API_KEY',
        '-t', image_tag,
        '-f', 'Dockerfile',
        '.'
      ]

      build_env = ENV.to_h.merge(
        'DOCKER_BUILDKIT' => '1',
        'PUPPET_CORE_API_KEY' => api_key
      )

      stage = @stage.run_stage('build_sut_image', build_cmd, build_dir, build_env)
      [image_tag, stage]
    end

    # Writes a clean setfile YAML that references a pre-built local image.
    # No secrets are embedded in this file.
    def write_clean_setfile(base_path, image_tag, docker_mode: 'sshd')
      base = YAML.safe_load(File.read(base_path), permitted_classes: [Symbol])
      hosts_key = base['HOSTS']&.keys&.first
      raise "No HOSTS entry found in setfile #{base_path}" unless hosts_key

      host_cfg = base['HOSTS'][hosts_key]
      host_cfg['image'] = image_tag
      host_cfg['docker_image_commands'] = []  # everything is in the pre-built image

      if docker_mode == 'systemd'
        # Systemd mode: container runs /usr/sbin/init as PID 1.
        # SSH is started by systemd (sshd.service), not as the entrypoint.
        # Requires privileged container with appropriate mounts.
        host_cfg['docker_cmd'] = '/usr/sbin/init'
      else
        # Override beaker-docker's default command (`service sshd start; tail -f /dev/null`),
        # which fails in non-systemd containers and causes ECONNRESET loops.
        host_cfg['docker_cmd'] = '/usr/sbin/sshd -D -e'
      end

      out_dir = File.join(@workspace_dir, '.beaker-setfiles')
      FileUtils.mkdir_p(out_dir)
      out_path = File.join(out_dir, "#{File.basename(base_path, '.*')}-puppetcore.yml")
      File.write(out_path, YAML.dump(base))
      File.expand_path(out_path)
    end

    # Removes all secret-bearing keys from an env hash so that untrusted
    # subprocess code cannot read them.
    def self.strip_secrets_from_env!(env)
      %w[
        PUPPET_CORE_API_KEY
        PASSWORD
        USERNAME
        BUNDLE_RUBYGEMS___PUPPETCORE__PUPPET__COM
      ].each { |key| env.delete(key) }
    end

    private

    # Generates a Dockerfile that installs puppet-agent from Puppet Core repos.
    # Credentials are consumed from a BuildKit secret mount and are never stored
    # in image layers or build metadata.
    def puppet_core_dockerfile(base_image, setup_commands, variant, version, puppet_major, docker_mode: 'sshd')
      collection = "puppet#{puppet_major}"
      lines = []
      lines << '# syntax=docker/dockerfile:1.4'
      lines << "FROM #{base_image}"
      # Ensure Puppet agent binaries are discoverable during Beaker SSH sessions.
      lines << 'ENV PATH="/opt/puppetlabs/bin:${PATH}"'

      # Run the base setfile setup commands (cronie, initscripts, etc.)
      setup_commands.each { |cmd| lines << "RUN #{cmd}" } unless setup_commands.empty?

      case variant
      when 'el', 'centos', 'redhat', 'rocky', 'alma', 'fedora', 'amazon'
        release_rpm = "https://yum-puppetcore.puppet.com/public/#{collection}-release-#{variant}-#{version}.noarch.rpm"
        repo_file = "/etc/yum.repos.d/#{collection}-release.repo"
        lines << "RUN --mount=type=secret,id=puppet_core_api_key \\" \
                 "\n PUPPET_CORE_API_KEY=\"$(cat /run/secrets/puppet_core_api_key)\" \\" \
                 "\n && rpm -Uvh #{release_rpm} \\" \
                 "\n && sed -i '/^\\[#{collection}\\]/a username=forge-key\\npassword='\"$PUPPET_CORE_API_KEY\" #{repo_file} \\" \
                 "\n && dnf install -y puppet-agent || yum install -y puppet-agent \\" \
                 "\n && rm -f #{repo_file}"
        lines << "RUN dnf install -y openssh-server openssh-clients passwd || yum install -y openssh-server openssh-clients passwd"
      when 'debian', 'ubuntu'
        release_deb_url = "https://apt-puppetcore.puppet.com/public/#{collection}-release-$(. /etc/os-release && echo $VERSION_CODENAME).deb"
        auth_file = "/etc/apt/auth.conf.d/#{collection}-puppetcore.conf"
        lines << "RUN --mount=type=secret,id=puppet_core_api_key \\" \
                 "\n PUPPET_CORE_API_KEY=\"$(cat /run/secrets/puppet_core_api_key)\" \\" \
                 "\n && apt-get update -qq && apt-get install -y wget \\" \
                 "\n && wget -O /tmp/#{collection}-release.deb \"#{release_deb_url}\" \\" \
                 "\n && dpkg -i /tmp/#{collection}-release.deb \\" \
                 "\n && mkdir -p /etc/apt/auth.conf.d \\" \
                 "\n && echo \"machine apt-puppetcore.puppet.com login forge-key password $PUPPET_CORE_API_KEY\" > #{auth_file} \\" \
                 "\n && apt-get update -qq && apt-get install -y puppet-agent openssh-server openssh-client passwd \\" \
                 "\n && ln -sf /opt/puppetlabs/bin/puppet /usr/bin/puppet \\" \
                 "\n && ln -sf /opt/puppetlabs/bin/facter /usr/bin/facter \\" \
                 "\n && ln -sf /opt/puppetlabs/bin/hiera /usr/bin/hiera \\" \
                 "\n && command -v puppet \\" \
                 "\n && puppet --version \\" \
                 "\n && rm -f #{auth_file} \\" \
                 "\n && grep -RIl --exclude-dir=preferences.d apt-puppetcore.puppet.com /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | xargs -r rm -f || true"
      else
        raise "Unsupported platform variant '#{variant}' for Puppet Core agent install"
      end

      # Configure SSH for Beaker connectivity.
      lines << <<~'RUN_SSH'.strip
        RUN mkdir -p /var/run/sshd \
         && ssh-keygen -A \
         && if grep -Eq '^#?PermitRootLogin' /etc/ssh/sshd_config; then sed -ri 's/^#?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config; else echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config; fi \
         && if grep -Eq '^#?PasswordAuthentication' /etc/ssh/sshd_config; then sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config; else echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config; fi \
         && if grep -Eq '^#?UsePAM' /etc/ssh/sshd_config; then sed -ri 's/^#?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config; else echo 'UsePAM no' >> /etc/ssh/sshd_config; fi \
         && echo 'root:root' | chpasswd
      RUN_SSH
      lines << 'EXPOSE 22'

      if docker_mode == 'systemd'
        # Systemd mode: use /usr/sbin/init as PID 1 so systemd manages all
        # services (including sshd). This requires the container to run
        # privileged with appropriate cgroup mounts.
        lines << 'RUN systemctl enable sshd.service'
        lines << 'CMD ["/usr/sbin/init"]'
      else
        # sshd mode: run sshd directly as PID 1 without systemd.
        # This is the default — faster and more portable, but services
        # that require systemd (e.g. chronyd) will not function.
        lines << 'CMD ["/bin/sh", "-lc", "mkdir -p /var/run/sshd; ssh-keygen -A >/dev/null 2>&1 || true; exec /usr/sbin/sshd -D -e"]'
      end

      lines.join("\n") + "\n"
    end
  end
end
