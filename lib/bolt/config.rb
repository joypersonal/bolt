require 'yaml'
require 'logging'
require 'bolt/cli'
require 'bolt/transport/ssh'
require 'bolt/transport/winrm'
require 'bolt/transport/orch'
require 'bolt/transport/local'

module Bolt
  TRANSPORTS = {
    ssh: Bolt::Transport::SSH,
    winrm: Bolt::Transport::WinRM,
    pcp: Bolt::Transport::Orch,
    local: Bolt::Transport::Local
  }.freeze

  Config = Struct.new(
    :concurrency,
    :format,
    :inventoryfile,
    :log_level,
    :log,
    :modulepath,
    :puppetdb,
    :transport,
    :transports
  ) do

    DEFAULTS = {
      concurrency: 100,
      transport: 'ssh',
      format: 'human',
      modulepath: [],
      puppetdb: {}
    }.freeze

    TRANSPORT_OPTIONS = %i[password run-as sudo-password extensions
                           private-key tty tmpdir user connect-timeout
                           cacert token-file service-url].freeze

    TRANSPORT_DEFAULTS = {
      'connect-timeout' => 10,
      'tty' => false
    }.freeze

    TRANSPORT_SPECIFIC_DEFAULTS = {
      ssh: {
        'host-key-check' => true
      },
      winrm: {
        'ssl' => true
      },
      pcp: {
        'task-environment' => 'production',
        'local-validation' => false
      },
      local: {}
    }.freeze

    def initialize(**kwargs)
      super()
      @logger = Logging.logger[self]
      DEFAULTS.merge(kwargs).each { |k, v| self[k] = v }

      # add an entry for the default console logger
      self[:log] ||= {}
      self[:log]['console'] ||= {}

      self[:transports] ||= {}
      TRANSPORTS.each_key do |transport|
        self[:transports][transport] ||= {}

        TRANSPORT_DEFAULTS.each do |k, v|
          unless self[:transports][transport][k]
            self[:transports][transport][k] = v
          end
        end

        TRANSPORT_SPECIFIC_DEFAULTS[transport].each do |k, v|
          unless self[:transports][transport].key? k
            self[:transports][transport][k] = v
          end
        end
      end
    end

    def deep_clone
      Bolt::Util.deep_clone(self)
    end

    def default_paths
      root_path = File.expand_path(File.join('~', '.puppetlabs'))
      [File.join(root_path, 'bolt.yaml'), File.join(root_path, 'bolt.yml')]
    end

    def normalize_log(target)
      return target if target == 'console'
      target = target[5..-1] if target.start_with?('file:')
      'file:' << File.expand_path(target)
    end

    def update_from_file(data)
      if data['log'].is_a?(Hash)
        data['log'].each_pair do |k, v|
          log = (self[:log][normalize_log(k)] ||= {})

          next unless v.is_a?(Hash)

          if v.key?('level')
            log[:level] = v['level'].to_s
          end

          if v.key?('append')
            log[:append] = v['append']
          end
        end
      end

      if data['modulepath']
        self[:modulepath] = data['modulepath'].split(File::PATH_SEPARATOR)
      end

      %w[inventoryfile concurrency format puppetdb].each do |key|
        if data[key]
          self[key.to_sym] = data[key]
        end
      end

      TRANSPORTS.each do |key, impl|
        if data[key.to_s]
          selected = data[key.to_s].select { |k| impl.options.include?(k) }
          self[:transports][key].merge!(selected)
        end
      end
    end
    private :update_from_file

    def load_file(path)
      data = Bolt::Util.read_config_file(path, default_paths, 'config')
      update_from_file(data) if data
    end

    def update_from_cli(options)
      %i[concurrency transport format modulepath inventoryfile].each do |key|
        self[key] = options[key] if options[key]
      end

      if options[:debug]
        self[:log]['console'][:level] = :debug
      elsif options[:verbose]
        self[:log]['console'][:level] = :info
      end

      TRANSPORTS.each_key do |transport|
        transport = self[:transports][transport]
        TRANSPORT_OPTIONS.each do |key|
          if options[key]
            transport[key.to_s] = Bolt::Util.walk_keys(options[key], &:to_s)
          end
        end
      end

      if options.key?(:ssl) # this defaults to true so we need to check the presence of the key
        self[:transports][:winrm]['ssl'] = options[:ssl]
      end

      if options.key?(:'host-key-check') # this defaults to true so we need to check the presence of the key
        self[:transports][:ssh]['host-key-check'] = options[:'host-key-check']
      end
    end

    def update_from_inventory(data)
      update_from_file(data)

      if data['transport']
        self[:transport] = data['transport']
      end
    end

    def transport_conf
      { transport: self[:transport],
        transports: self[:transports] }
    end

    def validate
      TRANSPORTS.each_key do |transport|
        self[:transports][transport]
      end

      self[:log].each_pair do |name, params|
        if params.key?(:level) && !Bolt::Logger.valid_level?(params[:level])
          raise Bolt::CLIError,
                "level of log #{name} must be one of: #{Bolt::Logger.levels.join(', ')}; received #{params[:level]}"
        end
        if params.key?(:append) && params[:append] != true && params[:append] != false
          raise Bolt::CLIError, "append flag of log #{name} must be a Boolean, received #{params[:append]}"
        end
      end

      unless %w[human json].include? self[:format]
        raise Bolt::CLIError, "Unsupported format: '#{self[:format]}'"
      end

      if self[:transports][:ssh]['sudo-password'] && self[:transports][:ssh]['run-as'].nil?
        @logger.warn("--sudo-password will not be used without specifying a " \
                     "user to escalate to with --run-as")
      end

      host_key = self[:transports][:ssh]['host-key-check']
      unless !!host_key == host_key
        raise Bolt::CLIError, 'host-key-check option must be a Boolean true or false'
      end

      ssl_flag = self[:transports][:winrm]['ssl']
      unless !!ssl_flag == ssl_flag
        raise Bolt::CLIError, 'ssl option must be a Boolean true or false'
      end

      validation_flag = self[:transports][:pcp]['local-validation']
      unless !!validation_flag == validation_flag
        raise Bolt::CLIError, 'local-validation option must be a Boolean true or false'
      end

      if (key_opt = self[:transports][:ssh]['private-key'])
        unless key_opt.instance_of?(String) || (key_opt.instance_of?(Hash) && key_opt.include?('key-data'))
          raise Bolt::CLIError,
                "private-key option must be the path to a private key file or a hash containing the 'key-data'"
        end
      end

      self[:transports].each_value do |v|
        timeout_value = v['connect-timeout']
        unless timeout_value.is_a?(Integer) || timeout_value.nil?
          error_msg = "connect-timeout value must be an Integer, received #{timeout_value}:#{timeout_value.class}"
          raise Bolt::CLIError, error_msg
        end
      end
    end
  end
end
